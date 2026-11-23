import Foundation
import UserNotifications
import XCTest
@testable import MediTrack

final class ViewModelTests: XCTestCase {
    @MainActor
    func testOfflineLoggingUpdatesTodayAndHistoryThenReconnectSyncs() async throws {
        let original = TestValues.log()
        let now = original.loggedAt
        let store = SwiftDataMedicationStore(container: try SwiftDataMedicationStore.makeContainer(inMemory: true))
        let medication = TestValues.medication()
        try store.replaceMedications([medication])
        let api = ScriptedClinicAPI(statuses: [201])
        let connectivity = TestConnectivity()
        let reminders = TestReminders()
        let model = try MediTrackModel(
            store: store, api: api, connectivity: connectivity, reminders: reminders,
            now: { now }, calendar: { TestValues.calendar() }
        )
        model.updateScene(active: true)
        connectivity.continuation.yield(false)

        let row = try XCTUnwrap(model.doses(at: now).first)
        XCTAssertEqual(row.status, .due)
        model.record(.skipped, for: row.occurrence)
        XCTAssertEqual(model.doses(at: now).first?.status, .skipped)
        XCTAssertEqual(model.detail(for: medication).history.first?.decision, .skipped)
        XCTAssertEqual(model.pendingCount, 1)

        connectivity.continuation.yield(true)
        for _ in 0..<100 {
            if model.pendingCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isOnline)
        XCTAssertEqual(model.detail(for: medication).history.first?.syncState, .synced)
        let submissions = await api.submittedIDs
        XCTAssertEqual(submissions, [row.id])
        model.updateScene(active: false)
        connectivity.continuation.finish()
    }

    @MainActor
    func testNotificationSnoozesOriginalSlotAndTakenUsesTheSameOfflineLog() async throws {
        let log = TestValues.log()
        let store = SwiftDataMedicationStore(container: try SwiftDataMedicationStore.makeContainer(inMemory: true))
        try store.replaceMedications([TestValues.medication()])
        let reminders = TestReminders()
        let model = try MediTrackModel(
            store: store, api: ScriptedClinicAPI(statuses: []), connectivity: TestConnectivity(),
            reminders: reminders, now: { log.loggedAt }, calendar: { TestValues.calendar() }
        )
        let payload = ReminderPayload(dose: log.occurrence)
        await model.handleReminder(.snooze, payload: payload)
        XCTAssertEqual(reminders.snoozed.map(\.dose), [log.occurrence])

        await model.handleReminder(.taken, payload: payload)
        await model.handleReminder(.taken, payload: payload)
        await model.handleReminder(.snooze, payload: payload)
        XCTAssertEqual(try store.pendingLogs(), [log])
        XCTAssertEqual(reminders.snoozed.count, 1)
        XCTAssertTrue(reminders.canceled.contains(log.occurrence))
    }
}

private struct TestConnectivity: ConnectivitySource {
    let stream: AsyncStream<Bool>
    let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func updates() -> AsyncStream<Bool> { stream }
}

@MainActor
private final class TestReminders: ReminderScheduling {
    private(set) var snoozed: [PlannedReminder] = []
    private(set) var canceled: [DoseOccurrence] = []

    func authorization() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func reconcile(_ plan: [PlannedReminder], snapshot: MedicationSnapshot) async throws {}
    func cancel(dose: DoseOccurrence) { canceled.append(dose) }
    func snooze(_ reminder: PlannedReminder) async throws { snoozed.append(reminder) }
}
