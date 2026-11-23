import Foundation
import UserNotifications

struct PlannedReminder: Equatable {
    let dose: DoseOccurrence
    let medication: Medication
}

enum ReminderPlan {
    static let horizonDays = 14
    static let regularLimit = 60
    static let totalLimit = 64

    static func upcoming(
        medications: [Medication], logs: [String: DoseLog], now: Date, calendar: Calendar
    ) -> [PlannedReminder] {
        let byID = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })
        let day = calendar.startOfDay(for: now)
        return (0..<horizonDays).lazy.compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            .flatMap { CivilSchedule.occurrences(for: medications, on: $0, calendar: calendar) }
            .compactMap { dose in
                guard dose.scheduledAt > now, logs[dose.id] == nil, let medication = byID[dose.medicationID] else {
                    return nil
                }
                return PlannedReminder(dose: dose, medication: medication)
            }
            .prefix(regularLimit)
            .map { $0 }
    }
}

enum ReminderAction: Sendable {
    case taken, snooze

    var identifier: String {
        switch self {
        case .taken: "MEDI_TRACK_TAKEN"
        case .snooze: "MEDI_TRACK_SNOOZE"
        }
    }

    init?(identifier: String) {
        switch identifier {
        case Self.taken.identifier: self = .taken
        case Self.snooze.identifier: self = .snooze
        default: return nil
        }
    }
}

struct ReminderPayload: Sendable {
    static let category = "MEDI_TRACK_DOSE"
    static let regularPrefix = "dose:"
    static let snoozePrefix = "snooze:"

    let dose: DoseOccurrence

    var userInfo: [AnyHashable: Any] {
        [
            "medication": dose.medicationID,
            "day": dose.day,
            "time": dose.time,
            "scheduledAt": dose.scheduledAt.timeIntervalSince1970
        ]
    }

    init(dose: DoseOccurrence) {
        self.dose = dose
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let medication = userInfo["medication"] as? String, !medication.isEmpty,
              let day = userInfo["day"] as? String, CivilSchedule.isValidDay(day),
              let time = userInfo["time"] as? String, CivilSchedule.timeComponents(time) != nil,
              let seconds = userInfo["scheduledAt"] as? Double, seconds.isFinite else { return nil }
        dose = DoseOccurrence(
            medicationID: medication, day: day, time: time, scheduledAt: Date(timeIntervalSince1970: seconds)
        )
    }

    var regularID: String { Self.regularPrefix + dose.id }
    var snoozeID: String { Self.snoozePrefix + dose.id }
}

@MainActor
protocol ReminderScheduling {
    func authorization() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func reconcile(_ plan: [PlannedReminder], snapshot: MedicationSnapshot) async throws
    func cancel(dose: DoseOccurrence)
    func snooze(_ reminder: PlannedReminder) async throws
}

@MainActor
final class LocalReminders: ReminderScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func configure(delegate: DoseNotificationDelegate) {
        center.delegate = delegate
        let actions = [
            UNNotificationAction(identifier: ReminderAction.taken.identifier, title: "Taken", options: []),
            UNNotificationAction(identifier: ReminderAction.snooze.identifier, title: "Snooze 10 min", options: [])
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderPayload.category, actions: actions, intentIdentifiers: [])
        ])
    }

    func authorization() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func reconcile(_ plan: [PlannedReminder], snapshot: MedicationSnapshot) async throws {
        guard await authorization().allowsReminders else { return }
        let pending = await center.pendingNotificationRequests()
        let medicationIDs = Set(snapshot.medications.map(\.id))
        let snoozes = pending.filter { request in
            guard request.identifier.hasPrefix(ReminderPayload.snoozePrefix),
                  let dose = ReminderPayload(userInfo: request.content.userInfo)?.dose else { return false }
            return snapshot.logs[dose.id] == nil && medicationIDs.contains(dose.medicationID)
        }
        let snoozeIDs = Set(snoozes.map(\.identifier))
        let desired = plan.prefix(max(0, ReminderPlan.totalLimit - snoozes.count))
        let regularIDs = Set(desired.map { ReminderPayload(dose: $0.dose).regularID })
        let stale = pending.filter {
            $0.content.categoryIdentifier == ReminderPayload.category
                && !regularIDs.contains($0.identifier) && !snoozeIDs.contains($0.identifier)
        }
        center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))

        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
        for reminder in desired where reminder.dose.scheduledAt > Date() {
            let payload = ReminderPayload(dose: reminder.dose)
            let content = content(for: reminder)
            if let previous = pendingByID[payload.regularID],
               ReminderPayload(userInfo: previous.content.userInfo)?.dose == reminder.dose,
               previous.content.body == content.body { continue }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let components = calendar.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                from: reminder.dose.scheduledAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try await center.add(UNNotificationRequest(identifier: payload.regularID, content: content, trigger: trigger))
        }
    }

    func cancel(dose: DoseOccurrence) {
        let payload = ReminderPayload(dose: dose)
        let identifiers = [payload.regularID, payload.snoozeID]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func snooze(_ reminder: PlannedReminder) async throws {
        let payload = ReminderPayload(dose: reminder.dose)
        let pending = await center.pendingNotificationRequests()
        if pending.count >= ReminderPlan.totalLimit, !pending.contains(where: { $0.identifier == payload.snoozeID }) {
            let regular = pending.filter { $0.identifier.hasPrefix(ReminderPayload.regularPrefix) }
            guard let furthest = regular.max(by: { scheduledAt($0) < scheduledAt($1) }) else {
                throw ReminderError.capacity
            }
            center.removePendingNotificationRequests(withIdentifiers: [furthest.identifier])
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: payload.snoozeID, content: content(for: reminder), trigger: trigger
        ))
    }

    private func scheduledAt(_ request: UNNotificationRequest) -> Date {
        ReminderPayload(userInfo: request.content.userInfo)?.dose.scheduledAt ?? .distantPast
    }

    private func content(for reminder: PlannedReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Medication reminder"
        content.body = "\(reminder.medication.name) · \(reminder.medication.dosage)"
        content.categoryIdentifier = ReminderPayload.category
        content.sound = .default
        content.userInfo = ReminderPayload(dose: reminder.dose).userInfo
        return content
    }

    private enum ReminderError: LocalizedError {
        case capacity

        var errorDescription: String? { "There are too many reminders waiting to be delivered." }
    }
}

extension UNAuthorizationStatus {
    var allowsReminders: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}

final class DoseNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let handle: @MainActor @Sendable (ReminderAction, ReminderPayload) async -> Void

    init(handle: @escaping @MainActor @Sendable (ReminderAction, ReminderPayload) async -> Void) {
        self.handle = handle
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == ReminderPayload.category,
              let action = ReminderAction(identifier: response.actionIdentifier),
              let payload = ReminderPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await handle(action, payload)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
