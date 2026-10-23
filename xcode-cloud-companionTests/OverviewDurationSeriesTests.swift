import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewDurationSeriesTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let english = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Thursday 23 October 2026, 14:32.
    private var now: Date { date(10, 23, 14, 32) }
    private var words: OverviewDurationWords { OverviewDurationWords(locale: english, calendar: calendar) }

    private func run(
        _ number: Int, at created: Date, minutes: Double, status: CICompletionStatus? = .succeeded, progress: CIExecutionProgress = .complete
    ) -> CIBuildRun {
        CIBuildRun(
            id: "w-\(number)", productID: "p", number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func series(_ runs: [CIBuildRun], days: Int = OverviewMosaic.defaultDays) -> OverviewDurationSeries? {
        var workflow = CIWorkflow(id: "w", name: "Release – iOS", testDestinationCounts: [])
        workflow.productID = "p"
        let snapshot = BuildSnapshot(
            products: [CIProduct(id: "p", name: "Brioche", productType: "APP", appID: nil, appName: nil, bundleID: nil)], runs: runs, workflows: [workflow]
        )
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
        let mosaic = OverviewMosaic(snapshot: snapshot, sidebar: sidebar, now: now, calendar: calendar, days: days)
        guard let row = mosaic.rows.first else { return nil }
        return OverviewDurationSeries(row: row, snapshot: snapshot, now: now, calendar: calendar)
    }

    // MARK: - Curve

    @Test func theColumnsAreTheMosaicsAndTheMedianIsOfTheDaysSuccessfulBuilds() throws {
        let runs = [
            run(1, at: date(10, 21, 9), minutes: 10), run(2, at: date(10, 21, 10), minutes: 20), run(3, at: date(10, 21, 11), minutes: 40),
            run(4, at: date(10, 23, 9), minutes: 8),
        ]

        let result = try #require(series(runs))

        #expect(result.dayCount == 35)
        #expect(result.points.last?.day == date(10, 23, 0))
        let tuesday = try #require(result.points.first { $0.day == date(10, 21, 0) })
        #expect(tuesday.medianSeconds == 20 * 60 && tuesday.builds == 3)
        #expect(result.points.last?.medianSeconds == 8.0 * 60)
        #expect(result.maximumSeconds == 20 * 60 && result.minimumSeconds == 8 * 60)
    }

    @Test func aDayWithoutASuccessIsAGapNotAZero() throws {
        let runs = [
            run(1, at: date(10, 21, 9), minutes: 10),
            run(2, at: date(10, 22, 9), minutes: 50, status: .failed),
            run(3, at: date(10, 22, 10), minutes: 5, status: .canceled),
            run(4, at: date(10, 22, 11), minutes: 0, status: nil, progress: .running),
        ]

        let result = try #require(series(runs))

        let wednesday = try #require(result.points.first { $0.day == date(10, 22, 0) })
        #expect(wednesday.medianSeconds == nil && wednesday.builds == 0)
        #expect(result.points.compactMap(\.medianSeconds) == [600], "no zero anywhere")
    }

    @Test func aSuccessWithoutDurationIsNotCounted() throws {
        var odd = run(2, at: date(10, 21, 10), minutes: 99)
        odd = CIBuildRun(
            id: odd.id, productID: "p", number: 2, createdDate: odd.createdDate, startedDate: nil, finishedDate: nil, executionProgress: .complete,
            completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
        )

        let result = try #require(series([run(1, at: date(10, 21, 9), minutes: 10), odd]))

        #expect(result.points.first { $0.day == date(10, 21, 0) }?.medianSeconds == 600)
    }

    @Test func aWorkflowWithoutSuccessHasNoData() throws {
        let result = try #require(series([run(1, at: date(10, 21, 9), minutes: 10, status: .failed)]))

        #expect(!result.hasData && result.maximumSeconds == nil)
        #expect(result.step == nil)
        #expect(words.spoken(result) == "Durations of Release – iOS over 35 days, no successful build")
    }

    // MARK: - Step

    /// 30 successful builds, one a day, the last ten of them slower.
    private func slowRuns(before: Double = 8 + 40.0 / 60, after: Double = 12) -> [CIBuildRun] {
        (0..<30).map { index in
            let day = calendar.date(byAdding: .day, value: index - 29, to: date(10, 23, 9))!
            return run(index + 1, at: day, minutes: index < 20 ? before : after)
        }
    }

    @Test func theLevelChangeComesFromWorkflowSlowdownWithItsColumn() throws {
        let result = try #require(series(slowRuns()))

        let step = try #require(result.step)
        #expect(step.runID == "w-21" && step.number == 21)
        #expect(abs(step.medianBefore - 520) < 0.001 && step.medianAfter == 720)
        #expect(abs(step.increase - (720.0 - 520) / 520) < 0.0001)
        #expect(step.column == 34 - 9, "the build created nine days before today sits in that column")
        #expect(result.points[try #require(step.column)].day == calendar.startOfDay(for: try #require(step.date)))
    }

    @Test func noLevelChangeNoStep() throws {
        let flat = (0..<30).map { run($0 + 1, at: calendar.date(byAdding: .day, value: $0 - 29, to: date(10, 23, 9))!, minutes: 10) }

        #expect(try #require(series(flat)).step == nil)
    }

    @Test func aStepOutsideTheColumnsHasNoColumnButKeepsItsFigures() throws {
        let result = try #require(series(slowRuns(), days: 5))

        let step = try #require(result.step)
        #expect(step.column == nil && step.number == 21)
    }

    // MARK: - Words

    @Test func theFiguresAreSaidLikeOnTheBoard() throws {
        let step = try #require(series(slowRuns())?.step)

        #expect(words.beforeLine(step) == "before: ~8 min 40")
        #expect(words.afterLine(step) == "since: ~12 min")
        #expect(words.increase(step) == "+38%")
        #expect(words.sinceLine(step) == "since Oct 14, #21")
    }

    @Test func aDurationIsRoundedToTenSecondsAndNeverOverflowsTheMinute() {
        #expect(words.approximate(526) == "~8 min 50")
        #expect(words.approximate(719) == "~12 min")
        #expect(words.approximate(45) == "~45 sec")
        #expect(words.approximate(3_900) == "~1 hr, 5 min")
    }

    @Test func voiceOverTellsTheStepWhenThereIsOne() throws {
        let result = try #require(series(slowRuns()))

        #expect(words.spoken(result) == "Durations of Release – iOS over 35 days, up 38% since October 14")
    }

    @Test func voiceOverTellsTheTrendWhenThereIsNoStep() throws {
        // Fourteen builds are too few for a step; a week at 10 min 24 against a week at 10 min is under the 15 % threshold.
        let runs = (0..<14).map { run($0 + 1, at: calendar.date(byAdding: .day, value: $0 - 13, to: date(10, 23, 9))!, minutes: $0 < 7 ? 10 : 10.4) }
        let result = try #require(series(runs))

        #expect(result.step == nil)
        #expect(words.spoken(result) == "Durations of Release – iOS over 35 days, stable over the last 7 days")
    }
}
