import Foundation
import Testing
@testable import XcodeCloudCompanion

struct UsagePlanTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    @Test func futureAnchorIsTheNextReset() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(2026, 11, 7, 14, 48))

        #expect(plan.nextReset(after: date(2026, 10, 9, 12), calendar: calendar) == date(2026, 11, 7, 14, 48))
    }

    @Test func passedAnchorMovesForwardMonthByMonth() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(2026, 11, 7, 14, 48))

        #expect(plan.nextReset(after: date(2026, 11, 7, 14, 48), calendar: calendar) == date(2026, 12, 7, 14, 48))
        #expect(plan.nextReset(after: date(2027, 3, 20), calendar: calendar) == date(2027, 4, 7, 14, 48))
    }

    @Test func farFutureAnchorStepsBackToTheUpcomingReset() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(2027, 2, 7, 14, 48))

        #expect(plan.nextReset(after: date(2026, 10, 9), calendar: calendar) == date(2026, 11, 7, 14, 48))
    }

    @Test func endOfMonthAnchorComesBackOnTheThirtyFirst() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(2027, 1, 31, 9))

        #expect(plan.nextReset(after: date(2027, 2, 1), calendar: calendar) == date(2027, 2, 28, 9))
        #expect(plan.nextReset(after: date(2027, 3, 1), calendar: calendar) == date(2027, 3, 31, 9))
    }

    @Test func localTimeIsKeptAcrossDaylightSavingChanges() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(2026, 10, 7, 14, 48))

        let next = plan.nextReset(after: date(2026, 10, 9), calendar: calendar)
        #expect(calendar.dateComponents([.hour, .minute], from: next) == DateComponents(hour: 14, minute: 48))
        #expect(next == date(2026, 11, 7, 14, 48))
    }
}
