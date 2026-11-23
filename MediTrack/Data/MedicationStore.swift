import Foundation
import SwiftData

@Model
final class MedicationRecord {
    @Attribute(.unique) var id: String
    var name: String
    var dosage: String
    var instructions: String
    var schedule: [String]
    var startDate: String
    var endDate: String?

    init(_ medication: Medication) {
        id = medication.id
        name = medication.name
        dosage = medication.dosage
        instructions = medication.instructions
        schedule = medication.schedule
        startDate = medication.startDate
        endDate = medication.endDate
    }

    var value: Medication {
        Medication(id: id, name: name, dosage: dosage, instructions: instructions,
                   schedule: schedule, startDate: startDate, endDate: endDate)
    }

    func update(from medication: Medication) {
        name = medication.name
        dosage = medication.dosage
        instructions = medication.instructions
        schedule = medication.schedule
        startDate = medication.startDate
        endDate = medication.endDate
    }
}

@Model
final class DoseLogRecord {
    @Attribute(.unique) var id: String
    var medicationID: String
    var day: String
    var time: String
    var scheduledAt: Date
    var loggedAt: Date
    var decision: DoseDecision
    var syncState: String
    var attempts: Int
    var nextAttemptAt: Date
    var failure: String?

    init(_ log: DoseLog) {
        id = log.id
        medicationID = log.occurrence.medicationID
        day = log.occurrence.day
        time = log.occurrence.time
        scheduledAt = log.occurrence.scheduledAt
        loggedAt = log.loggedAt
        decision = log.decision
        syncState = log.syncState.rawValue
        attempts = log.attempts
        nextAttemptAt = log.nextAttemptAt
        failure = log.failure
    }

    var value: DoseLog {
        let occurrence = DoseOccurrence(medicationID: medicationID, day: day, time: time, scheduledAt: scheduledAt)
        var log = DoseLog(occurrence: occurrence, decision: decision, loggedAt: loggedAt)
        log.syncState = SyncState(rawValue: syncState) ?? .failed
        log.attempts = attempts
        log.nextAttemptAt = nextAttemptAt
        log.failure = failure
        return log
    }

    func updateSync(from log: DoseLog) {
        syncState = log.syncState.rawValue
        attempts = log.attempts
        nextAttemptAt = log.nextAttemptAt
        failure = log.failure
    }
}

struct MedicationSnapshot {
    var medications: [Medication] = []
    var logs: [String: DoseLog] = [:]
}

@MainActor
protocol MedicationStore {
    func snapshot() throws -> MedicationSnapshot
    func replaceMedications(_ medications: [Medication]) throws
    func log(_ candidate: DoseLog) throws -> DoseLog
    func log(for id: String) throws -> DoseLog?
    func pendingLogs() throws -> [DoseLog]
    func saveSync(_ log: DoseLog) throws
    func retryFailed(now: Date) throws
}

@MainActor
final class SwiftDataMedicationStore: MedicationStore {
    private let context: ModelContext

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([MedicationRecord.self, DoseLogRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func snapshot() throws -> MedicationSnapshot {
        let medications = try context.fetch(FetchDescriptor<MedicationRecord>(sortBy: [SortDescriptor(\.name)]))
        let logs = try context.fetch(FetchDescriptor<DoseLogRecord>()).map(\.value)
        return MedicationSnapshot(medications: medications.map(\.value), logs: Dictionary(uniqueKeysWithValues: logs.map { ($0.id, $0) }))
    }

    func replaceMedications(_ medications: [Medication]) throws {
        let records = try context.fetch(FetchDescriptor<MedicationRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let incomingIDs = Set(medications.map(\.id))
        for record in records where !incomingIDs.contains(record.id) {
            context.delete(record)
        }
        for medication in medications {
            if let record = byID[medication.id] {
                record.update(from: medication)
            } else {
                context.insert(MedicationRecord(medication))
            }
        }
        try save()
    }

    func log(_ candidate: DoseLog) throws -> DoseLog {
        if let existing = try log(for: candidate.id) { return existing }
        context.insert(DoseLogRecord(candidate))
        try save()
        return candidate
    }

    func log(for id: String) throws -> DoseLog? {
        try record(for: id)?.value
    }

    func pendingLogs() throws -> [DoseLog] {
        let pending = SyncState.pending.rawValue
        let request = FetchDescriptor<DoseLogRecord>(
            predicate: #Predicate { $0.syncState == pending },
            sortBy: [SortDescriptor(\.nextAttemptAt), SortDescriptor(\.loggedAt), SortDescriptor(\.id)]
        )
        return try context.fetch(request).map(\.value)
    }

    func saveSync(_ log: DoseLog) throws {
        guard let record = try record(for: log.id) else { throw StoreError.missingLog }
        record.updateSync(from: log)
        try save()
    }

    func retryFailed(now: Date) throws {
        let failed = SyncState.failed.rawValue
        let records = try context.fetch(FetchDescriptor<DoseLogRecord>(predicate: #Predicate { $0.syncState == failed }))
        for record in records {
            record.syncState = SyncState.pending.rawValue
            record.attempts = 0
            record.nextAttemptAt = now
            record.failure = nil
        }
        try save()
    }

    private func record(for id: String) throws -> DoseLogRecord? {
        var request = FetchDescriptor<DoseLogRecord>(predicate: #Predicate { $0.id == id })
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private enum StoreError: Error {
        case missingLog
    }
}
