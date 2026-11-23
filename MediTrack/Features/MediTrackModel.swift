import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class MediTrackModel {
    private(set) var snapshot: MedicationSnapshot
    private(set) var isOnline = false
    private(set) var isRefreshing = false
    private(set) var reminderAuthorization: UNAuthorizationStatus = .notDetermined
    var alert: String?
    var refreshError: String?

    let showsDemoControls: Bool
    private(set) var demoOffline: Bool

    @ObservationIgnored private let store: any MedicationStore
    @ObservationIgnored private let api: any ClinicAPI
    @ObservationIgnored private let connectivity: any ConnectivitySource
    @ObservationIgnored private let reminders: any ReminderScheduling
    @ObservationIgnored private let queue: DoseSyncQueue
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var reminderWork: Task<Void, Never>?
    @ObservationIgnored private var refreshWork: Task<Void, Never>?
    @ObservationIgnored private var physicalConnection = false
    @ObservationIgnored private var active = false

    init(
        store: any MedicationStore, api: any ClinicAPI, connectivity: any ConnectivitySource,
        reminders: any ReminderScheduling, now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = CivilSchedule.localCalendar,
        showsDemoControls: Bool = false, demoOffline: Bool = false
    ) throws {
        self.store = store
        self.api = api
        self.connectivity = connectivity
        self.reminders = reminders
        self.now = now
        self.calendar = calendar
        self.showsDemoControls = showsDemoControls
        self.demoOffline = demoOffline
        snapshot = try store.snapshot()
        queue = DoseSyncQueue(store: store, api: api, now: now)
        queue.onChange = { [weak self] in self?.reload() }
        queue.onStoreError = { [weak self] _ in self?.alert = "Couldn’t update sync status. MediTrack will try again." }
    }

    var pendingCount: Int { snapshot.logs.values.filter { $0.syncState == .pending }.count }
    var failedCount: Int { snapshot.logs.values.filter { $0.syncState == .failed }.count }

    func doses(at date: Date) -> [DoseRow] {
        CivilSchedule.today(medications: snapshot.medications, logs: snapshot.logs, now: date, calendar: calendar())
    }

    func detail(for medication: Medication) -> MedicationDetailModel {
        let history = snapshot.logs.values.filter { $0.occurrence.medicationID == medication.id }
            .sorted {
                if $0.occurrence.scheduledAt != $1.occurrence.scheduledAt {
                    return $0.occurrence.scheduledAt > $1.occurrence.scheduledAt
                }
                return $0.id < $1.id
            }
        return MedicationDetailModel(
            medication: snapshot.medications.first { $0.id == medication.id } ?? medication,
            history: history
        )
    }

    func updateScene(active: Bool) {
        self.active = active
        if monitoring == nil {
            let updates = connectivity.updates()
            monitoring = Task { [weak self] in
                for await connected in updates {
                    guard let self else { return }
                    self.physicalConnection = connected
                    self.updateConnection()
                }
            }
        }
        queue.setAvailable(active && isOnline)
        if active {
            startRefresh()
            updateReminders()
        }
    }

    func setDemoOffline(_ offline: Bool) {
        guard showsDemoControls else { return }
        demoOffline = offline
        updateConnection()
    }

    func refresh() async {
        startRefresh()
        await refreshWork?.value
        queue.kick()
    }

    func record(_ decision: DoseDecision, for occurrence: DoseOccurrence) {
        do {
            let log = try store.log(DoseLog(occurrence: occurrence, decision: decision, loggedAt: now()))
            snapshot.logs[log.id] = log
            updateReminders(cancel: occurrence)
            queue.kick()
        } catch {
            alert = "Couldn’t save this dose. Please try again."
        }
    }

    func retryFailed() {
        do {
            try store.retryFailed(now: now())
            reload()
            queue.kick()
        } catch {
            alert = "Couldn’t reset failed logs. Please try again."
        }
    }

    func enableReminders() async {
        do {
            _ = try await reminders.requestAuthorization()
            updateReminders()
            await reminderWork?.value
        } catch {
            alert = "Couldn’t request notification access. Please try again."
        }
    }

    func significantTimeChanged() {
        guard active else { return }
        updateReminders()
        queue.kick()
    }

    func handleReminder(_ action: ReminderAction, payload: ReminderPayload) async {
        let dose = payload.dose
        switch action {
        case .taken:
            record(.taken, for: dose)
        case .snooze:
            enqueueReminderWork { model in
                guard model.snapshot.logs[dose.id] == nil,
                      let medication = model.snapshot.medications.first(where: { $0.id == dose.medicationID }) else {
                    return
                }
                try await model.reminders.snooze(PlannedReminder(dose: dose, medication: medication))
            }
            await reminderWork?.value
        }
    }

    private func updateConnection() {
        let previouslyOnline = isOnline
        isOnline = physicalConnection && !demoOffline
        queue.setAvailable(active && isOnline)
        if isOnline && !previouslyOnline && active { startRefresh() }
    }

    private func startRefresh() {
        guard isOnline, refreshWork == nil else { return }
        isRefreshing = true
        refreshError = nil
        refreshWork = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                self.refreshWork = nil
            }
            do {
                let medications = try await self.api.medications()
                try self.store.replaceMedications(medications)
                self.reload()
                self.updateReminders()
            } catch {
                self.refreshError = "Couldn’t refresh medications. Saved medications are still available."
            }
        }
    }

    private func reload() {
        do {
            snapshot = try store.snapshot()
        } catch {
            alert = "Couldn’t read saved medications and dose logs."
        }
    }

    private func updateReminders(cancel dose: DoseOccurrence? = nil) {
        enqueueReminderWork { model in
            if let dose { model.reminders.cancel(dose: dose) }
            model.reminderAuthorization = await model.reminders.authorization()
            guard model.reminderAuthorization.allowsReminders else { return }
            let snapshot = model.snapshot
            let plan = ReminderPlan.upcoming(
                medications: snapshot.medications, logs: snapshot.logs, now: model.now(), calendar: model.calendar()
            )
            try await model.reminders.reconcile(plan, snapshot: snapshot)
        }
    }

    private func enqueueReminderWork(_ operation: @escaping @MainActor (MediTrackModel) async throws -> Void) {
        let preceding = reminderWork
        reminderWork = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            do {
                try await operation(self)
            } catch {
                self.alert = "Couldn’t update a medication reminder."
            }
        }
    }

    deinit {
        monitoring?.cancel()
    }
}

struct MedicationDetailModel {
    let medication: Medication
    let history: [DoseLog]
}
