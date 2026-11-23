import Foundation
import XCTest
@testable import MediTrack

final class ScheduleTests: XCTestCase {
    func testStatusBoundariesAndLoggedDecisions() {
        let date = Date(timeIntervalSince1970: 30_000)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date.addingTimeInterval(-1_801), decision: nil), .upcoming)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date.addingTimeInterval(-1_800), decision: nil), .due)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date, decision: nil), .due)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date.addingTimeInterval(1_800), decision: nil), .due)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date.addingTimeInterval(1_801), decision: nil), .missed)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date, decision: .taken), .taken)
        XCTAssertEqual(DoseStatus(scheduledAt: date, now: date, decision: .skipped), .skipped)
    }

    func testInclusiveDatesSortingAndDuplicateSlots() {
        let calendar = TestValues.calendar("Asia/Kolkata")
        let medications = [
            TestValues.medication(),
            TestValues.medication(id: "course", schedule: ["23:00", "07:00", "07:00", "15:00"],
                                  start: "2026-11-20", end: "2026-11-27"),
            TestValues.medication(id: "future", start: "2026-12-01")
        ]
        for day in [20, 27] {
            let now = TestValues.date(2026, 11, day, calendar: calendar)
            let rows = CivilSchedule.today(medications: medications, logs: [:], now: now, calendar: calendar)
            XCTAssertEqual(rows.map(\.occurrence.time), ["07:00", "08:00", "15:00", "20:00", "23:00"])
            XCTAssertEqual(rows.first?.occurrence.day, "2026-11-\(day)")
        }
        for day in [19, 28] {
            let now = TestValues.date(2026, 11, day, calendar: calendar)
            let rows = CivilSchedule.today(medications: medications, logs: [:], now: now, calendar: calendar)
            XCTAssertEqual(rows.map(\.medication.id), ["med_001", "med_001"])
        }
    }

    func testSpringGapAndFallOverlapHaveOneOccurrence() throws {
        let calendar = TestValues.calendar("America/New_York")
        let spring = TestValues.date(2027, 3, 14, calendar: calendar)
        let fall = TestValues.date(2027, 11, 7, calendar: calendar)
        let springDoses = CivilSchedule.occurrences(
            for: [TestValues.medication(schedule: ["02:30"])], on: spring, calendar: calendar
        )
        let fallDoses = CivilSchedule.occurrences(
            for: [TestValues.medication(schedule: ["01:30"])], on: fall, calendar: calendar
        )
        XCTAssertEqual(springDoses.count, 1)
        let shifted = try XCTUnwrap(springDoses.first?.scheduledAt)
        XCTAssertEqual(calendar.component(.hour, from: shifted), 3)
        XCTAssertEqual(calendar.component(.minute, from: shifted), 30)
        XCTAssertEqual(fallDoses.count, 1)
        XCTAssertEqual(fallDoses.first?.scheduledAt, TestValues.date(2027, 11, 7, hour: 5, minute: 30))
    }

    func testTravelPreservesSlotIdentityAndAppliesLogToToday() throws {
        let medication = TestValues.medication(schedule: ["08:00"])
        let home = TestValues.calendar("Asia/Kolkata")
        let away = TestValues.calendar("America/New_York")
        let homeNoon = TestValues.date(2026, 11, 23, hour: 12, calendar: home)
        let awayNoon = TestValues.date(2026, 11, 23, hour: 12, calendar: away)
        let dose = try XCTUnwrap(CivilSchedule.occurrences(for: [medication], on: homeNoon, calendar: home).first)
        let log = DoseLog(occurrence: dose, decision: .taken, loggedAt: homeNoon)
        let rows = CivilSchedule.today(medications: [medication], logs: [log.id: log], now: awayNoon, calendar: away)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, dose.id)
        XCTAssertNotEqual(row.occurrence.scheduledAt, dose.scheduledAt)
        XCTAssertEqual(row.status, .taken)
    }

    func testReminderPlanExcludesLoggedAndPastSlotsAndCapsPending() throws {
        let calendar = TestValues.calendar()
        let now = TestValues.date(2026, 11, 23, hour: 12, calendar: calendar)
        let medications = (0..<5).map { TestValues.medication(id: "med_\($0)") }
        let firstFuture = try XCTUnwrap(CivilSchedule.occurrences(for: medications, on: now, calendar: calendar)
            .first { $0.scheduledAt > now })
        let log = DoseLog(occurrence: firstFuture, decision: .skipped, loggedAt: now)
        let reminders = ReminderPlan.upcoming(medications: medications, logs: [log.id: log], now: now, calendar: calendar)
        XCTAssertEqual(reminders.count, ReminderPlan.regularLimit)
        XCTAssertTrue(reminders.allSatisfy { $0.dose.scheduledAt > now && $0.dose.id != log.id })
        let dates = reminders.map(\.dose.scheduledAt)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testReminderPayloadRoundTripPreservesOriginalDose() throws {
        let dose = TestValues.log().occurrence
        let encoded = ReminderPayload(dose: dose)
        let decoded = try XCTUnwrap(ReminderPayload(userInfo: encoded.userInfo))
        XCTAssertEqual(decoded.dose, dose)
        XCTAssertNotEqual(decoded.regularID, decoded.snoozeID)
        XCTAssertNil(ReminderPayload(userInfo: ["medication": "invalid"]))
        XCTAssertEqual(ReminderAction(identifier: ReminderAction.taken.identifier), .taken)
    }
}

enum TestValues {
    static func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0,
        calendar: Calendar = calendar()
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func medication(
        id: String = "med_001", schedule: [String] = ["08:00", "20:00"], start: String = "2026-11-01",
        end: String? = nil
    ) -> Medication {
        Medication(id: id, name: "Metformin", dosage: "500 mg", instructions: "Take after food",
                   schedule: schedule, startDate: start, endDate: end)
    }

    static func log(id: String = "med_001", decision: DoseDecision = .taken) -> DoseLog {
        let scheduledAt = date(2026, 11, 23, hour: 8)
        let dose = DoseOccurrence(medicationID: id, day: "2026-11-23", time: "08:00", scheduledAt: scheduledAt)
        return DoseLog(occurrence: dose, decision: decision, loggedAt: scheduledAt.addingTimeInterval(128))
    }
}
