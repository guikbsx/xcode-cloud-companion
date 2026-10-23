import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewMosaicTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!

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

    private func run(
        _ number: Int, workflow: String = "w", at created: Date, minutes: Double = 10, progress: CIExecutionProgress = .complete,
        status: CICompletionStatus? = .succeeded, product: String = "p"
    ) -> CIBuildRun {
        CIBuildRun(
            id: "\(workflow)-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: workflow, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func workflow(_ id: String, _ name: String, product: String = "p", enabled: Bool? = nil) -> CIWorkflow {
        var workflow = CIWorkflow(id: id, name: name, testDestinationCounts: [])
        workflow.productID = product
        workflow.isEnabled = enabled
        return workflow
    }

    private func product(_ id: String, _ name: String) -> CIProduct {
        CIProduct(id: id, name: name, productType: "APP", appID: nil, appName: nil, bundleID: nil)
    }

    private func mosaic(
        _ runs: [CIBuildRun], workflows: [CIWorkflow]? = nil, products: [CIProduct]? = nil, summary: UsageSummary? = nil,
        days: Int = OverviewMosaic.defaultDays, at moment: Date? = nil
    ) -> OverviewMosaic {
        let snapshot = BuildSnapshot(products: products ?? [product("p", "Pollen")], runs: runs, workflows: workflows ?? [workflow("w", "Main")])
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
        return OverviewMosaic(snapshot: snapshot, sidebar: sidebar, summary: summary, now: moment ?? now, calendar: calendar, days: days)
    }

    private func row(_ runs: [CIBuildRun], days: Int = OverviewMosaic.defaultDays) -> OverviewMosaic.Row? {
        mosaic(runs, days: days).rows.first
    }

    // MARK: - Columns

    @Test func thereAreThirtyFiveColumnsEndingTodayAndTheCountIsAParameter() {
        let result = mosaic([run(1, at: date(10, 23, 9))])

        #expect(result.days.count == 35)
        #expect(result.days.last == date(10, 23, 0))
        #expect(result.days.first == date(9, 19, 0))
        #expect(result.rows.first?.cells.count == 35)
        #expect(mosaic([run(1, at: date(10, 23, 9))], days: 14).days.count == 14)
    }

    @Test func aDayWithoutBuildIsEmpty() throws {
        let cells = try #require(row([run(1, at: date(10, 23, 9))])).cells

        let empty = cells[cells.count - 2]
        #expect(empty.builds == 0 && empty.outcome == .none && empty.intensity == 0)
    }

    @Test func aDayWithOnlySuccessesIsSucceededAndOnlyFailuresFailed() throws {
        let cells = try #require(row([
            run(1, at: date(10, 21, 9)), run(2, at: date(10, 21, 10)),
            run(3, at: date(10, 22, 9), status: .failed), run(4, at: date(10, 22, 10), status: .errored),
        ])).cells

        #expect(cells[cells.count - 3].outcome == .succeeded && cells[cells.count - 3].builds == 2)
        #expect(cells[cells.count - 2].outcome == .failed && cells[cells.count - 2].failed == 2)
    }

    @Test func aMixedDayHasBothAndCountsEveryBuild() throws {
        let cell = try #require(row([
            run(1, at: date(10, 22, 8)), run(2, at: date(10, 22, 9), status: .failed), run(3, at: date(10, 22, 10)),
        ])).cells[33]

        #expect(cell.outcome == .mixed)
        #expect(cell.succeeded == 2 && cell.failed == 1 && cell.builds == 3 && cell.intensity == 3)
    }

    @Test func aCanceledOrSkippedBuildCountsAsABuildButNeitherAsSuccessNorFailure() throws {
        let cell = try #require(row([
            run(1, at: date(10, 22, 8), status: .canceled), run(2, at: date(10, 22, 9), status: .skipped),
            run(3, at: date(10, 23, 9)),
        ])).cells[33]

        #expect(cell.builds == 2 && cell.succeeded == 0 && cell.failed == 0)
        #expect(cell.outcome == .none && cell.intensity == 2)
    }

    @Test func intensityStopsAtFour() throws {
        let runs = (1...6).map { run($0, at: date(10, 22, 6 + $0)) }

        #expect(try #require(row(runs)).cells[33].intensity == 4)
    }

    @Test func aBuildBelongsToTheDayItWasCreatedEvenIfItEndsAfterMidnight() throws {
        let result = try #require(row([run(1, at: date(10, 21, 23, 50), minutes: 30)]))

        #expect(result.cells[32].builds == 1 && result.cells[32].outcome == .succeeded)
        #expect(result.cells[33].builds == 0)
    }

    @Test func aBuildWithoutCreationDateFallsBackOnItsStart() throws {
        let build = CIBuildRun(
            id: "x", productID: "p", number: 1, createdDate: nil, startedDate: date(10, 22, 9), finishedDate: date(10, 22, 10),
            executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
        )

        #expect(try #require(row([build])).cells[33].builds == 1)
    }

    @Test func theOctoberClockChangeDoesNotShiftADay() throws {
        // Europe/Paris goes back an hour on Sunday 25 October 2026: that day lasts 25 hours.
        let sunday = date(10, 25, 0)
        let result = mosaic(
            [
                run(1, at: date(10, 24, 23, 30)), run(2, at: date(10, 25, 0, 30), status: .failed),
                run(3, at: date(10, 25, 23, 30)), run(4, at: date(10, 26, 0, 30)),
            ],
            at: date(10, 27, 9)
        )
        let cells = try #require(result.rows.first).cells

        #expect(result.days.suffix(4) == [date(10, 24, 0), sunday, date(10, 26, 0), date(10, 27, 0)])
        #expect(Set(result.days).count == 35, "every day appears once")
        #expect(cells[31].builds == 1 && cells[31].outcome == .succeeded)
        #expect(cells[32].builds == 2 && cells[32].outcome == .mixed)
        #expect(cells[33].builds == 1)
        #expect(cells[34].builds == 0)
    }

    @Test func aBuildAfterNowOrBeforeThePeriodIsLeftOut() throws {
        let result = try #require(row([run(1, at: date(10, 23, 18)), run(2, at: date(9, 1, 9)), run(3, at: date(10, 23, 9))]))

        #expect(result.cells.reduce(0) { $0 + $1.builds } == 1)
    }

    @Test func todayCountsRunningAndQueuedBuilds() throws {
        let cells = try #require(row([
            run(1, at: date(10, 23, 8)), run(2, at: date(10, 23, 13), progress: .running, status: nil),
            run(3, at: date(10, 23, 14), progress: .pending, status: nil), run(4, at: date(10, 23, 14, 10), progress: .pending, status: nil),
        ])).cells

        let today = try #require(cells.last)
        #expect(today.builds == 4 && today.running == 1 && today.queued == 2)
        #expect(today.outcome == .succeeded, "unfinished builds give no verdict")
        #expect(cells.dropLast().allSatisfy { $0.running == 0 && $0.queued == 0 })
    }

    // MARK: - Rows

    @Test func rowsFollowTheSidebarAppsThenWorkflowNames() {
        let products = [product("a", "Alpha"), product("b", "Beta")]
        let workflows = [workflow("a2", "Release", product: "a"), workflow("a1", "Beta checks", product: "a"), workflow("b1", "Main", product: "b")]
        // Beta has the newest build, so the sidebar lists it first.
        let runs = [
            run(1, workflow: "a1", at: date(10, 20, 9), product: "a"), run(2, workflow: "a2", at: date(10, 21, 9), product: "a"),
            run(3, workflow: "b1", at: date(10, 22, 9), product: "b"),
        ]

        let result = mosaic(runs, workflows: workflows, products: products)

        #expect(result.groups.map(\.name) == ["Beta", "Alpha"])
        #expect(result.rows.map(\.name) == ["Main", "Beta checks", "Release"])
        #expect(result.groups[1].rows.map(\.productID) == ["a", "a"])
    }

    @Test func aWorkflowWithoutBuildInThePeriodHasNoRowAndIsCounted() {
        let workflows = [workflow("w", "Main"), workflow("old", "Archive"), workflow("never", "Weekly")]
        let runs = [run(1, at: date(10, 22, 9)), run(2, workflow: "old", at: date(8, 1, 9))]

        let result = mosaic(runs, workflows: workflows)

        #expect(result.rows.map(\.name) == ["Main"])
        #expect(result.hiddenWorkflowCount == 2)
    }

    @Test func anAppWithoutAnyRowIsLeftOut() {
        let result = mosaic([run(1, at: date(10, 22, 9))], workflows: [workflow("w", "Main"), workflow("x", "Other", product: "q")], products: [product("p", "Pollen"), product("q", "Quartz")])

        #expect(result.groups.map(\.name) == ["Pollen"])
        #expect(result.hiddenWorkflowCount == 1)
    }

    @Test func aPausedWorkflowKeepsItsRowAndSaysSo() throws {
        let paused = try #require(mosaic([run(1, at: date(10, 22, 9))], workflows: [workflow("w", "Main", enabled: false)]).rows.first)
        let active = try #require(mosaic([run(1, at: date(10, 22, 9))], workflows: [workflow("w", "Main", enabled: true)]).rows.first)

        #expect(paused.isPaused && !active.isPaused)
        #expect(paused.cells[33].builds == 1)
    }

    @Test func noSnapshotGivesAnEmptyMosaic() {
        let result = mosaic([], workflows: [])

        #expect(result.isEmpty && result.hiddenWorkflowCount == 0 && result.days.count == 35)
    }

    // MARK: - End of row

    @Test func theSuccessRateLooksAtTheLastSevenDaysAndIgnoresCanceledAndSkippedBuilds() throws {
        let result = try #require(row([
            run(1, at: date(10, 17, 9)), run(2, at: date(10, 18, 9), status: .failed), run(3, at: date(10, 20, 9)), run(4, at: date(10, 21, 9)),
            run(5, at: date(10, 22, 9), status: .canceled), run(6, at: date(10, 22, 10), status: .skipped), run(7, at: date(10, 23, 9), progress: .running, status: nil),
            run(8, at: date(10, 16, 9), status: .failed),
        ]))

        // 17 to 23 October: one failure out of four verdicts. The 16th is the day before the window.
        #expect(result.successRate == 0.75)
    }

    @Test func theSuccessRateIsNilWithoutAFinishedBuild() throws {
        #expect(try #require(row([run(1, at: date(10, 23, 9), progress: .running, status: nil)])).successRate == nil)
        #expect(try #require(row([run(1, at: date(10, 1, 9))])).successRate == nil, "nothing in the last seven days")
    }

    @Test func theMedianDurationIsThatOfTheSucceededBuildsOfTheLastSevenDays() throws {
        let result = try #require(row([
            run(1, at: date(10, 18, 9), minutes: 10), run(2, at: date(10, 19, 9), minutes: 20), run(3, at: date(10, 20, 9), minutes: 30),
            run(4, at: date(10, 21, 9), minutes: 90, status: .failed),
        ]))

        #expect(abs((result.medianSeconds ?? 0) - 20 * 60) < 0.001)
    }

    @Test func theTrendComparesTheLastSevenDaysWithTheSevenBefore() throws {
        func trend(recent: Double, earlier: Double, recentCount: Int = 3, earlierCount: Int = 3) throws -> OverviewMosaic.Trend {
            let recentRuns = (0..<recentCount).map { run(100 + $0, at: date(10, 17 + $0, 9), minutes: recent) }
            let earlierRuns = (0..<earlierCount).map { run(200 + $0, at: date(10, 10 + $0, 9), minutes: earlier) }
            return try #require(row(recentRuns + earlierRuns)).trend
        }

        #expect(try trend(recent: 12, earlier: 10) == .up(0.2))
        #expect(try trend(recent: 8, earlier: 10) == .down(-0.2))
        #expect(try trend(recent: 11, earlier: 10) == .stable)
        #expect(try trend(recent: 12, earlier: 10, earlierCount: 2) == .unknown)
        #expect(try trend(recent: 12, earlier: 10, recentCount: 2) == .unknown)
    }

    @Test func theCycleMinutesAreTakenFromTheSummaryAsTheyAre() throws {
        let plan = UsagePlan(hours: 25, resetAnchor: date(10, 5, 0))
        var summary = UsageSummary(
            plan: plan, cycle: plan.cycle(containing: now, calendar: calendar), now: now, billedMinutes: 100, estimatedMinutes: 50,
            estimatedBuildCount: 2, lastImport: nil, daily: [], buildsLast30Days: 0, byApp: []
        )
        summary.byWorkflow = [
            WorkflowUsage(product: "Pollen", workflow: "Main", billedMinutes: 120, estimatedMinutes: 30, buildCount: 5),
            WorkflowUsage(product: "Pollen", workflow: "Other", billedMinutes: 10, estimatedMinutes: 0, buildCount: 1),
        ]
        let runs = [run(1, at: date(10, 22, 9))]

        let estimated = try #require(mosaic(runs, summary: summary).rows.first).cycle
        summary.byWorkflow[0].estimatedMinutes = 0
        let billed = try #require(mosaic(runs, summary: summary).rows.first).cycle

        #expect(estimated == OverviewMosaic.CycleMinutes(minutes: 150, isEstimated: true))
        #expect(billed == OverviewMosaic.CycleMinutes(minutes: 120, isEstimated: false))
    }

    @Test func theCycleMinutesAreNilWithoutAPlanOrWhileMeasuring() throws {
        let plan = UsagePlan(hours: 25, resetAnchor: date(10, 5, 0))
        var measuring = UsageSummary(
            plan: plan, cycle: plan.cycle(containing: now, calendar: calendar), now: now, billedMinutes: 0, estimatedMinutes: 10,
            estimatedBuildCount: 1, lastImport: nil, daily: [], buildsLast30Days: 0, byApp: []
        )
        measuring.byWorkflow = [WorkflowUsage(product: "Pollen", workflow: "Main", estimatedMinutes: 10, buildCount: 1)]
        measuring.measurement = MeasurementProgress(totalActions: 4, measuredActions: 1)
        let runs = [run(1, at: date(10, 22, 9))]

        #expect(try #require(mosaic(runs, summary: nil).rows.first).cycle == nil)
        #expect(measuring.measurement.isMeasuring)
        #expect(try #require(mosaic(runs, summary: measuring).rows.first).cycle == nil)
    }

    @Test func aWorkflowAbsentFromTheSummaryUsedNoMinutes() throws {
        let plan = UsagePlan(hours: 25, resetAnchor: date(10, 5, 0))
        let summary = UsageSummary(
            plan: plan, cycle: plan.cycle(containing: now, calendar: calendar), now: now, billedMinutes: 0, estimatedMinutes: 0,
            estimatedBuildCount: 0, lastImport: nil, daily: [], buildsLast30Days: 0, byApp: []
        )

        #expect(try #require(mosaic([run(1, at: date(9, 25, 9))], summary: summary).rows.first).cycle == OverviewMosaic.CycleMinutes(minutes: 0, isEstimated: false))
    }

    // MARK: - Failure series

    @Test func theSeriesStartsAtTheFirstFailureOfTheRunThatTouchesTheNewestFinishedBuild() throws {
        let result = try #require(row([
            run(201, at: date(10, 17, 9), status: .failed), run(202, at: date(10, 18, 9)),
            run(203, at: date(10, 21, 2), status: .failed), run(204, at: date(10, 22, 2), status: .errored), run(205, at: date(10, 23, 2), status: .failed),
            run(206, at: date(10, 23, 14), progress: .running, status: nil),
        ]))

        let series = try #require(result.failureSeries)
        #expect(series.firstNumber == 203 && series.firstRunID == "w-203" && series.lastNumber == 205 && series.lastRunID == "w-205")
        #expect(series.failureCount == 3 && !series.isOpenEnded)
        #expect(series.firstDay(calendar: calendar) == date(10, 21, 0))
    }

    @Test func aCanceledBuildInsideTheRunNeitherBreaksNorExtendsIt() throws {
        let series = try #require(row([
            run(1, at: date(10, 20, 9)), run(2, at: date(10, 21, 9), status: .failed), run(3, at: date(10, 22, 9), status: .canceled),
            run(4, at: date(10, 22, 12), status: .failed),
        ])?.failureSeries)

        #expect(series.failureCount == 2 && series.firstNumber == 2)
    }

    @Test func thereIsNoSeriesWhenTheNewestFinishedBuildSucceeded() throws {
        let result = try #require(row([run(1, at: date(10, 21, 9), status: .failed), run(2, at: date(10, 22, 9)), run(3, at: date(10, 23, 9), progress: .running, status: nil)]))

        #expect(result.failureSeries == nil)
    }

    @Test func aRunWithNoSuccessBeforeItIsOpenEnded() throws {
        let series = try #require(row([run(1, at: date(10, 21, 9), status: .failed), run(2, at: date(10, 22, 9), status: .failed)])?.failureSeries)

        #expect(series.failureCount == 2 && series.isOpenEnded)
    }

    @Test func aWorkflowWithOnlyUnfinishedBuildsHasNoSeries() throws {
        #expect(try #require(row([run(1, at: date(10, 23, 9), progress: .running, status: nil)])).failureSeries == nil)
    }

    // MARK: - The demonstration data

    @Test func theLastThreeDaysOfARedWorkflowReadRedAndTheOthersGreen() throws {
        let products = [product("s", "Sextant"), product("b", "Brioche")]
        let workflows = [workflow("nightly", "Nightly", product: "s"), workflow("main", "Main", product: "s"), workflow("rel", "Release – iOS", product: "b")]
        var runs: [CIBuildRun] = []
        for offset in 0..<10 {
            let day = 23 - offset
            runs.append(run(500 + offset, workflow: "main", at: date(10, day, 9), product: "s"))
            runs.append(run(600 + offset, workflow: "rel", at: date(10, day, 10), product: "b"))
            runs.append(run(200 + offset, workflow: "nightly", at: date(10, day, 2), status: offset < 3 ? .failed : .succeeded, product: "s"))
        }

        let result = mosaic(runs, workflows: workflows, products: products)

        let nightly = try #require(result.rows.first { $0.name == "Nightly" })
        #expect(nightly.cells.suffix(3).allSatisfy { $0.outcome == .failed })
        #expect(nightly.cells[31].outcome == .succeeded)
        #expect(nightly.failureSeries?.failureCount == 3)
        #expect(result.rows.filter { $0.name != "Nightly" }.allSatisfy { $0.cells.suffix(10).allSatisfy { $0.outcome == .succeeded } })
        #expect(result.buildsLastDays == 21)
    }
}
