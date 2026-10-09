import Foundation
import Testing
@testable import XcodeCloudCompanion

struct UsageEstimatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second)) ?? .distantPast
    }

    private func run(_ id: String, created: Date, started: Date?, finished: Date?, status: CICompletionStatus? = .succeeded) -> CIBuildRun {
        CIBuildRun(
            id: id, productID: "p", number: Int(id.dropFirst()) ?? 0, createdDate: created, startedDate: started, finishedDate: finished,
            executionProgress: finished == nil ? .running : .complete, completionStatus: finished == nil ? nil : status,
            startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func action(_ runID: String, started: Date, finished: Date?) -> CIBuildAction {
        CIBuildAction(
            id: UUID().uuidString, buildRunID: runID, name: nil, actionType: .test, startedDate: started, finishedDate: finished,
            executionProgress: finished == nil ? .running : .complete, completionStatus: nil, isRequiredToPass: nil
        )
    }

    /// r1: one 10 min build with two parallel actions (10 min and 4 min 10 s); r2: failed 3 min build; r3: running for 5 min.
    private var snapshot: BuildSnapshot {
        BuildSnapshot(
            runs: [
                run("r3", created: date(10, 9, 11, 55), started: date(10, 9, 11, 55), finished: nil),
                run("r2", created: date(10, 8, 9), started: date(10, 8, 9), finished: date(10, 8, 9, 3), status: .failed),
                run("r1", created: date(10, 7, 10), started: date(10, 7, 10), finished: date(10, 7, 10, 10)),
            ],
            actionsByRunID: [
                "r1": [action("r1", started: date(10, 7, 10), finished: date(10, 7, 10, 10)), action("r1", started: date(10, 7, 10), finished: date(10, 7, 10, 4, 10))],
                "r2": [action("r2", started: date(10, 8, 9), finished: date(10, 8, 9, 3))],
                "r3": [action("r3", started: date(10, 9, 11, 55), finished: nil)],
            ]
        )
    }

    @Test func actionsAddUpEvenWhenTheyRunInParallel() {
        let totals = UsageEstimator.totals(of: snapshot, in: DateInterval(start: date(10, 7), end: date(10, 8)), now: date(10, 9, 12))

        #expect(totals.buildCount == 1)
        #expect(totals.seconds(.buildRunDuration) == 10 * 60)
        #expect(totals.seconds(.actionDuration) == 14 * 60 + 10)
        #expect(totals.seconds(.actionDurationRoundedUpToMinute) == 15 * 60)
        #expect(totals.actionCountByType == ["TEST": 2])
        #expect(totals.actionSecondsByType == ["TEST": 14 * 60 + 10])
    }

    @Test func aRunningBuildCountsUpToNow() {
        let totals = UsageEstimator.totals(of: snapshot, in: DateInterval(start: date(10, 9), end: date(10, 10)), now: date(10, 9, 12))

        #expect(totals.buildCount == 1)
        #expect(totals.seconds(.actionDuration) == 5 * 60)
    }

    @Test func buildsCanBeFilteredByStatus() {
        let totals = UsageEstimator.totals(of: snapshot, in: DateInterval(start: date(10, 1), end: date(10, 10)), now: date(10, 9, 12)) {
            $0.completionStatus == .failed
        }

        #expect(totals.buildCount == 1)
        #expect(totals.seconds(.buildRunDuration) == 3 * 60)
    }

    @Test func cycleRunsFromTheLastResetToTheNextOne() {
        let plan = UsagePlan(hours: 25, resetAnchor: date(11, 7, 14, 48))

        let cycle = plan.cycle(containing: date(10, 9, 12), calendar: calendar)

        #expect(cycle.start == date(10, 7, 14, 48))
        #expect(cycle.end == date(11, 7, 14, 48))
    }

    @Test func cycleAfterAShortMonthStartsOnTheAnchorDay() {
        let plan = UsagePlan(hours: 25, resetAnchor: calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9)) ?? .distantPast)
        let march2 = calendar.date(from: DateComponents(year: 2027, month: 3, day: 2)) ?? .distantPast

        let cycle = plan.cycle(containing: march2, calendar: calendar)

        #expect(cycle.start == calendar.date(from: DateComponents(year: 2027, month: 2, day: 28, hour: 9)))
        #expect(cycle.end == calendar.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 9)))
    }

    @Test func diagnosticPeriodsMatchAppStoreConnectsTrendsLabels() {
        let periods = UsageDiagnostic.periods(plan: UsagePlan(hours: 25, resetAnchor: date(11, 7, 14, 48)), now: date(10, 9, 12), calendar: calendar)

        #expect(periods.map(\.interval.start) == [date(9, 8), date(9, 9), date(10, 7, 14, 48)])
        #expect(periods[0].interval.end == date(10, 9))
        #expect(periods[2].interval.end == date(10, 9, 12))
    }

    @Test func reportListsEveryMethodPerPeriodAndPerDay() {
        let report = UsageDiagnostic.report(snapshot: snapshot, plan: UsagePlan(hours: 25, resetAnchor: date(11, 7, 14, 48)), now: date(10, 9, 12), calendar: calendar)

        #expect(report.contains("Europe/Paris"))
        #expect(report.contains("Current cycle"))
        #expect(report.contains("FAILED"))
        #expect(report.contains("By action type"))
        #expect(report.contains("Test acts"))
        #expect(report.contains("0 h 14 min"))
        #expect(report.contains("0 h 15 min"))
        #expect(report.components(separatedBy: "\n").count > 31)
    }

    @Test func durationsReadAsHoursAndMinutes() {
        #expect(UsageDiagnostic.hoursAndMinutes(24 * 3600 + 43 * 60) == "24 h 43 min")
        #expect(UsageDiagnostic.hoursAndMinutes(59) == "0 h 01 min")
    }
}
