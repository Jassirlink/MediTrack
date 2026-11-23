import Foundation

struct Medication: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let dosage: String
    let instructions: String
    let schedule: [String]
    let startDate: String
    let endDate: String?

    var hasValidSchedule: Bool {
        guard !id.isEmpty, CivilSchedule.isValidDay(startDate),
              schedule.allSatisfy({ CivilSchedule.timeComponents($0) != nil }) else { return false }
        return endDate.map { CivilSchedule.isValidDay($0) && $0 >= startDate } ?? true
    }
}

enum DoseDecision: String, Codable, Sendable {
    case taken, skipped
}

enum SyncState: String, Sendable {
    case pending, synced, failed
}

struct DoseOccurrence: Equatable, Identifiable, Sendable {
    let medicationID: String
    let day: String
    let time: String
    let scheduledAt: Date

    // The identity represents a local prescription slot and survives time zone changes.
    var id: String { "\(medicationID)|\(day)|\(time)" }
}

struct DoseLog: Equatable, Identifiable, Sendable {
    let occurrence: DoseOccurrence
    let decision: DoseDecision
    let loggedAt: Date
    var syncState: SyncState
    var attempts: Int
    var nextAttemptAt: Date
    var failure: String?

    var id: String { occurrence.id }

    init(occurrence: DoseOccurrence, decision: DoseDecision, loggedAt: Date) {
        self.occurrence = occurrence
        self.decision = decision
        self.loggedAt = loggedAt
        syncState = .pending
        attempts = 0
        nextAttemptAt = loggedAt
    }
}

enum DoseStatus: String, Equatable, Sendable {
    case upcoming = "Upcoming"
    case due = "Due now"
    case taken = "Taken"
    case skipped = "Skipped"
    case missed = "Missed"

    init(scheduledAt: Date, now: Date, decision: DoseDecision?) {
        switch decision {
        case .taken: self = .taken
        case .skipped: self = .skipped
        case nil:
            let secondsUntilDose = scheduledAt.timeIntervalSince(now)
            if secondsUntilDose > 1_800 {
                self = .upcoming
            } else if secondsUntilDose < -1_800 {
                self = .missed
            } else {
                self = .due
            }
        }
    }
}

struct DoseRow: Identifiable, Equatable, Sendable {
    let medication: Medication
    let occurrence: DoseOccurrence
    let log: DoseLog?
    let status: DoseStatus

    var id: String { occurrence.id }
}
