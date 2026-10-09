import Foundation

nonisolated struct UsagePlan: Sendable, Equatable {
    static let availableHours = [25, 100, 250, 1000]
    static let defaultHours = 25

    var hours: Int
    /// Any past or future reset moment, as shown by App Store Connect; the other resets are monthly from it.
    var resetAnchor: Date

    /// Months are added to the anchor itself, never chained, so a reset on the 31st comes back on the 31st.
    func nextReset(after date: Date, calendar: Calendar = .current) -> Date {
        var offset = 0
        var candidate = reset(monthsFromAnchor: offset, calendar: calendar)
        while candidate <= date {
            offset += 1
            candidate = reset(monthsFromAnchor: offset, calendar: calendar)
        }
        while true {
            let previous = reset(monthsFromAnchor: offset - 1, calendar: calendar)
            guard previous > date else { return candidate }
            offset -= 1
            candidate = previous
        }
    }

    /// The cycle that contains `date`: from the last reset at or before it to the next one.
    func cycle(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: lastReset(atOrBefore: date, calendar: calendar), end: nextReset(after: date, calendar: calendar))
    }

    func lastReset(atOrBefore date: Date, calendar: Calendar = .current) -> Date {
        var offset = 0
        var candidate = reset(monthsFromAnchor: offset, calendar: calendar)
        while candidate > date {
            offset -= 1
            candidate = reset(monthsFromAnchor: offset, calendar: calendar)
        }
        while true {
            let next = reset(monthsFromAnchor: offset + 1, calendar: calendar)
            guard next <= date else { return candidate }
            offset += 1
            candidate = next
        }
    }

    private func reset(monthsFromAnchor months: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: months, to: resetAnchor) ?? resetAnchor
    }
}
