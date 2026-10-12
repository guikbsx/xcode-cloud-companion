import Foundation
import Testing
@testable import XcodeCloudCompanion

struct ScheduleForecastTests {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    /// Sunday 11 October 2026, 10:00 in Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-10-11T08:00:00Z") ?? .distantPast

    @Test func theNextRunFollowsTheFrequency() {
        let calendar = paris
        func next(_ schedule: CISchedule) -> Date? { ScheduleForecast.nextRun(of: schedule, after: now, calendar: calendar) }

        #expect(next(CISchedule(frequency: .hourly, minute: 30)) == date("2026-10-11T08:30:00Z"))
        #expect(next(CISchedule(frequency: .daily, hour: 12)) == date("2026-10-11T10:00:00Z"), "later today")
        #expect(next(CISchedule(frequency: .daily, hour: 2)) == date("2026-10-12T00:00:00Z"), "two o'clock is past: tomorrow")
        #expect(next(CISchedule(frequency: .weekly, weekdays: [2], hour: 6)) == date("2026-10-12T04:00:00Z"), "Monday")
        #expect(next(CISchedule(frequency: .weekly, weekdays: [1], hour: 9)) == date("2026-10-18T07:00:00Z"), "this Sunday's nine o'clock is past")
        #expect(next(CISchedule(frequency: .weekly, weekdays: [1, 3], hour: 9)) == date("2026-10-13T07:00:00Z"), "the soonest of the days")
        #expect(next(CISchedule(frequency: .weekly, hour: 9)) == nil, "a weekly schedule without a day fires never")
    }

    @Test func theScheduleKeepsItsOwnTimeZone() {
        let newYork = CISchedule(frequency: .daily, hour: 2, timeZoneID: "America/New_York")

        #expect(ScheduleForecast.nextRun(of: newYork, after: now, calendar: paris) == date("2026-10-12T06:00:00Z"))
    }

    @Test func theDayTheClocksGoBackHasOneRunLikeAnyOther() {
        // Paris leaves summer time on 25 October 2026.
        let before = date("2026-10-24T08:00:00Z")
        let daily = CISchedule(frequency: .daily, hour: 2, minute: 30)

        let next = ScheduleForecast.nextRun(of: daily, after: before, calendar: paris)
        #expect(next.map { paris.component(.hour, from: $0) } == 2 && next.map { paris.component(.day, from: $0) } == 25)
        #expect(ScheduleForecast.runs(of: daily, after: before, until: date("2026-10-26T08:00:00Z"), calendar: paris) == 2)
    }

    @Test func runsAreCountedUpToTheResetOnly() {
        let daily = CISchedule(frequency: .daily, hour: 2)

        #expect(ScheduleForecast.runs(of: daily, after: now, until: date("2026-10-11T10:00:00Z"), calendar: paris) == 0, "the cycle ends before two o'clock")
        #expect(ScheduleForecast.runs(of: daily, after: now, until: date("2026-10-14T08:00:00Z"), calendar: paris) == 3)
        #expect(ScheduleForecast.runs(of: CISchedule(frequency: .hourly), after: now, until: date("2026-10-11T11:00:00Z"), calendar: paris) == 3)
    }

    @Test func theForecastListsEnabledScheduledWorkflowsSoonestFirstWithTheirCost() {
        let product = CIProduct(id: "p", name: "cumulus", productType: "APP", appID: "1", appName: "Cumulus", bundleID: nil)
        func workflow(_ id: String, name: String, schedule: CISchedule?, isEnabled: Bool? = true) -> CIWorkflow {
            var workflow = CIWorkflow(id: id, name: name, testDestinationCounts: [])
            workflow.productID = "p"
            workflow.isEnabled = isEnabled
            workflow.startConditions = schedule.map { CIStartConditions(scheduleFrequency: $0.frequency, schedule: $0) }
            return workflow
        }
        let workflows = [
            workflow("w", name: "UI tests", schedule: CISchedule(frequency: .weekly, weekdays: [2], hour: 6, source: CIPatterns(isAllMatch: false, patterns: ["main"]))),
            workflow("n", name: "Nightly", schedule: CISchedule(frequency: .daily, hour: 2, source: CIPatterns(isAllMatch: true, patterns: []))),
            workflow("paused", name: "Paused", schedule: CISchedule(frequency: .daily, hour: 2), isEnabled: false),
            workflow("manual", name: "Release", schedule: nil),
        ]
        let usage = [WorkflowUsage(product: "cumulus", workflow: "Nightly", billedMinutes: 76, estimatedMinutes: 0, buildCount: 2)]

        let forecast = ScheduleForecast(workflows: workflows, products: [product], cycleEnd: date("2026-10-14T08:00:00Z"), usage: usage, now: now, calendar: paris)
        let noPlan = ScheduleForecast(workflows: workflows, products: [product], cycleEnd: nil, usage: [], now: now, calendar: paris)

        #expect(forecast.entries.map(\.workflowName) == ["Nightly", "UI tests"])
        #expect(forecast.entries[0].productName == "Cumulus" && forecast.entries[0].source == nil && forecast.entries[1].source == "main")
        #expect(forecast.entries[0].minutesPerRun == 38 && forecast.entries[0].runsUntilReset == 3)
        #expect(forecast.entries[1].minutesPerRun == nil && forecast.entries[1].runsUntilReset == 1)
        #expect(forecast.minutesUntilReset == 114 && forecast.hasUnestimatedRuns)
        #expect(noPlan.entries.count == 2 && noPlan.minutesUntilReset == nil && !noPlan.hasUnestimatedRuns)
    }

    @Test @MainActor func theOverviewWordsWhenABuildStartsAndWhatTheyCost() {
        let calendar = paris
        let english = Locale(identifier: "en_US")

        // Foundation puts a narrow no-break space before AM and PM.
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(plain(OverviewView.whenText(date("2026-10-11T12:00:00Z"), now: now, calendar: calendar, locale: english)) == "today 2:00 PM")
        #expect(plain(OverviewView.whenText(date("2026-10-12T00:00:00Z"), now: now, calendar: calendar, locale: english)) == "tomorrow 2:00 AM")
        #expect(OverviewView.whenText(date("2026-10-13T04:00:00Z"), now: now, calendar: calendar, locale: english).hasPrefix("Tuesday"))
        #expect(OverviewView.whenText(date("2026-10-25T04:00:00Z"), now: now, calendar: calendar, locale: english).contains("Oct"))
        #expect(OverviewView.frequencyText(.daily) == "every day")
        #expect(OverviewView.totalText(114, hasUnestimatedRuns: false).hasPrefix("By the end of the cycle"))
        #expect(OverviewView.totalText(114, hasUnestimatedRuns: true).hasSuffix("are not counted."))
    }
}
