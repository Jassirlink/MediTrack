import Foundation
import SwiftData
import XCTest
@testable import MediTrack

final class StoreAndSyncTests: XCTestCase {
    @MainActor
    func testFirstDecisionWinsAndCacheReplacementPreservesHistory() throws {
        let store = try makeStore()
        try store.replaceMedications([TestValues.medication(), TestValues.medication(id: "removed")])
        let original = TestValues.log()
        XCTAssertEqual(try store.log(original), original)
        XCTAssertEqual(try store.log(TestValues.log(decision: .skipped)), original)
        try store.replaceMedications([TestValues.medication(schedule: ["09:00"])])
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.medications.map(\.id), ["med_001"])
        XCTAssertEqual(snapshot.medications.first?.schedule, ["09:00"])
        XCTAssertEqual(snapshot.logs, [original.id: original])
        XCTAssertEqual(try store.pendingLogs(), [original])
    }

    @MainActor
    func testSavedCacheAndRetryStateSurviveOpeningNewContainer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([MedicationRecord.self, DoseLogRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "medications.store"))
        var log = TestValues.log(decision: .skipped)
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let store = SwiftDataMedicationStore(container: container)
            try store.replaceMedications([TestValues.medication()])
            _ = try store.log(log)
            RetryPolicy.reserveAttempt(for: &log, now: log.loggedAt)
            RetryPolicy.recordFailure(APIError.http(500), for: &log, now: log.loggedAt)
            try store.saveSync(log)
        }
        let reopened = SwiftDataMedicationStore(container: try ModelContainer(for: schema, configurations: configuration))
        XCTAssertEqual(try reopened.pendingLogs(), [log])
        XCTAssertEqual(try reopened.snapshot().medications, [TestValues.medication()])
    }

    @MainActor
    func testReconnectRetriesOnlyAtDeadlineWithoutDuplicateSubmission() async throws {
        let store = try makeStore()
        let log = TestValues.log()
        _ = try store.log(log)
        let clock = TestClock(now: log.loggedAt)
        let api = ScriptedClinicAPI(statuses: [500, 201])
        let queue = DoseSyncQueue(store: store, api: api, now: { clock.now })

        queue.kick()
        await queue.waitForCurrentPass()
        let offlineSubmissions = await api.submittedIDs
        XCTAssertTrue(offlineSubmissions.isEmpty)

        queue.setAvailable(true)
        queue.kick()
        queue.kick()
        await queue.waitForCurrentPass()
        let waiting = try XCTUnwrap(store.log(for: log.id))
        XCTAssertEqual(waiting.attempts, 1)
        XCTAssertEqual(waiting.syncState, .pending)
        XCTAssertEqual(waiting.nextAttemptAt, clock.now.addingTimeInterval(2))

        queue.setAvailable(false)
        clock.now = clock.now.addingTimeInterval(1)
        queue.setAvailable(true)
        await queue.waitForCurrentPass()
        let beforeDeadline = await api.submittedIDs
        XCTAssertEqual(beforeDeadline, [log.id])

        clock.now = waiting.nextAttemptAt
        queue.kick()
        await queue.waitForCurrentPass()
        let submissions = await api.submittedIDs
        XCTAssertEqual(submissions, [log.id, log.id])
        XCTAssertEqual(try store.log(for: log.id)?.syncState, .synced)
        XCTAssertTrue(try store.pendingLogs().isEmpty)
        queue.setAvailable(false)
    }

    @MainActor
    func testBackoffStopsAfterFiveAndAllowsExplicitRetry() async throws {
        let store = try makeStore()
        let log = TestValues.log()
        _ = try store.log(log)
        let clock = TestClock(now: log.loggedAt)
        let api = ScriptedClinicAPI(statuses: [500, 500, 500, 500, 500, 201])
        let queue = DoseSyncQueue(store: store, api: api, now: { clock.now })

        for attempt in 1...5 {
            queue.setAvailable(true)
            await queue.waitForCurrentPass()
            queue.setAvailable(false)
            let stored = try XCTUnwrap(store.log(for: log.id))
            XCTAssertEqual(stored.attempts, attempt)
            if attempt < 5 {
                XCTAssertEqual(stored.syncState, .pending)
                XCTAssertEqual(stored.nextAttemptAt.timeIntervalSince(clock.now), Double(1 << attempt))
                clock.now = stored.nextAttemptAt
            } else {
                XCTAssertEqual(stored.syncState, .failed)
                XCTAssertTrue(try store.pendingLogs().isEmpty)
            }
        }
        queue.setAvailable(true)
        await queue.waitForCurrentPass()
        let beforeManualRetry = await api.submittedIDs
        XCTAssertEqual(beforeManualRetry.count, 5)

        try store.retryFailed(now: clock.now)
        queue.kick()
        await queue.waitForCurrentPass()
        let afterManualRetry = await api.submittedIDs
        XCTAssertEqual(afterManualRetry, Array(repeating: log.id, count: 6))
        XCTAssertEqual(try store.log(for: log.id)?.syncState, .synced)
        queue.setAvailable(false)
    }

    @MainActor
    func testPermanentClientErrorDoesNotBlockAnotherLog() async throws {
        let store = try makeStore()
        let first = TestValues.log(id: "first")
        let second = TestValues.log(id: "second")
        _ = try store.log(first)
        _ = try store.log(second)
        let api = ScriptedClinicAPI(statuses: [400, 201])
        let queue = DoseSyncQueue(store: store, api: api, now: { first.loggedAt })
        queue.setAvailable(true)
        await queue.waitForCurrentPass()
        XCTAssertEqual(try store.log(for: first.id)?.syncState, .failed)
        XCTAssertEqual(try store.log(for: first.id)?.attempts, 1)
        XCTAssertEqual(try store.log(for: second.id)?.syncState, .synced)
        queue.setAvailable(false)
    }

    @MainActor
    func testInterruptedFifthAttemptDoesNotSendASixthRequest() async throws {
        let store = try makeStore()
        let log = TestValues.log()
        _ = try store.log(log)
        var reserved = log
        reserved.attempts = 4
        RetryPolicy.reserveAttempt(for: &reserved, now: log.loggedAt)
        try store.saveSync(reserved)
        let api = ScriptedClinicAPI(statuses: [201])
        let retryDate = reserved.nextAttemptAt
        let queue = DoseSyncQueue(store: store, api: api, now: { retryDate })
        queue.setAvailable(true)
        await queue.waitForCurrentPass()
        let submissions = await api.submittedIDs
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(try store.log(for: log.id)?.syncState, .failed)
        queue.setAvailable(false)
    }

    @MainActor
    private func makeStore() throws -> SwiftDataMedicationStore {
        SwiftDataMedicationStore(container: try SwiftDataMedicationStore.makeContainer(inMemory: true))
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

actor ScriptedClinicAPI: ClinicAPI {
    private var statuses: [Int]
    private(set) var submittedIDs: [String] = []

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    func medications() async throws -> [Medication] {
        [TestValues.medication()]
    }

    func submit(_ log: DoseLog) async throws {
        submittedIDs.append(log.id)
        let status = statuses.isEmpty ? 201 : statuses.removeFirst()
        guard status == 201 else { throw APIError.http(status) }
    }
}
