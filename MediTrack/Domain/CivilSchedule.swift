import Foundation

enum CivilSchedule {
    static func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func isValidDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [4, 2, 2],
              let year = Int(parts[0]), year > 0,
              let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        return calendar.date(from: components).map { day($0, calendar: calendar) == value } ?? false
    }

    static func timeComponents(_ value: String) -> DateComponents? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [2, 2], let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              String(format: "%02d:%02d", hour, minute) == value else { return nil }
        return DateComponents(hour: hour, minute: minute, second: 0)
    }

    static func occurrences(for medications: [Medication], on date: Date, calendar: Calendar) -> [DoseOccurrence] {
        let start = calendar.startOfDay(for: date)
        let localDay = day(start, calendar: calendar)
        return medications.flatMap { medication -> [DoseOccurrence] in
            guard medication.startDate <= localDay,
                  medication.endDate.map({ localDay <= $0 }) ?? true else { return [] }
            return Set(medication.schedule).compactMap { time in
                guard let components = timeComponents(time),
                      let scheduled = calendar.nextDate(
                        after: start.addingTimeInterval(-1),
                        matching: components,
                        matchingPolicy: .nextTimePreservingSmallerComponents,
                        repeatedTimePolicy: .first
                      ), calendar.isDate(scheduled, inSameDayAs: start) else { return nil }
                return DoseOccurrence(medicationID: medication.id, day: localDay, time: time, scheduledAt: scheduled)
            }
        }.sorted {
            if $0.scheduledAt != $1.scheduledAt { return $0.scheduledAt < $1.scheduledAt }
            return $0.id < $1.id
        }
    }

    static func today(medications: [Medication], logs: [String: DoseLog], now: Date, calendar: Calendar) -> [DoseRow] {
        let byID = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })
        return occurrences(for: medications, on: now, calendar: calendar).compactMap { occurrence in
            guard let medication = byID[occurrence.medicationID] else { return nil }
            let log = logs[occurrence.id]
            return DoseRow(
                medication: medication, occurrence: occurrence, log: log,
                status: DoseStatus(scheduledAt: occurrence.scheduledAt, now: now, decision: log?.decision)
            )
        }
    }
}
