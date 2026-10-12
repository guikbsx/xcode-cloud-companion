import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AppOverviewModelTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    /// Friday 9 October 2026 at noon; the cycle began on the 7th at 14:48.
    private var now: Date { date(10, 9, 12) }
    private var plan: UsagePlan { UsagePlan(hours: 25, resetAnchor: date(11, 7, 14, 48)) }

    private func run(
        _ number: Int, product: String = "p1", workflow: String, name: String, created: Date, status: CICompletionStatus = .succeeded,
        branch: String? = "main", pullRequest: Int? = nil, title: String? = nil
    ) -> CIBuildRun {
        var run = CIBuildRun(
            id: "r\(number)", productID: product, number: number, createdDate: created, startedDate: created.addingTimeInterval(20),
            finishedDate: created.addingTimeInterval(20 + 600), executionProgress: .complete, completionStatus: status,
            startReason: nil, workflowID: workflow, workflowName: name, sourceBranchOrTag: pullRequest == nil ? branch : nil
        )
        run.isPullRequestBuild = pullRequest != nil
        run.pullRequestNumber = pullRequest
        run.pullRequestTitle = title
        return run
    }

    private var workflows: [CIWorkflow] {
        var archive = CIWorkflow(id: "w1", name: "Public archive", testDestinationCounts: [])
        archive.productID = "p1"
        archive.xcodeVersion = "26.4"
        archive.xcodeVersionName = "Xcode 26.4"
        archive.actions = [CIWorkflowAction(name: "Archive", actionType: .archive, buildDistributionAudience: "APP_STORE_ELIGIBLE")]
        archive.startConditions = CIStartConditions(branches: CIPatterns(isAllMatch: false, patterns: ["main"]))

        var beta = CIWorkflow(id: "w2", name: "Beta testing", testDestinationCounts: [])
        beta.productID = "p1"
        beta.xcodeVersion = "27.1"
        beta.repositoryName = "guikbsx/realmotivation"
        beta.startConditions = CIStartConditions(schedule: CISchedule(frequency: .weekly, weekdays: [2], hour: 6, timeZoneID: "Europe/Paris"))

        var paused = CIWorkflow(id: "w3", name: "Internal archive", testDestinationCounts: [])
        paused.productID = "p1"
        paused.isEnabled = false
        paused.startConditions = CIStartConditions(schedule: CISchedule(frequency: .daily, hour: 2))

        var other = CIWorkflow(id: "w9", name: "Default", testDestinationCounts: [])
        other.productID = "p2"
        return [archive, beta, paused, other]
    }

    private var snapshot: BuildSnapshot {
        BuildSnapshot(
            products: [
                CIProduct(id: "p1", name: "realmotivation", productType: "APP", appID: "1", appName: "Crossfit Hyrox Tracker", bundleID: nil),
                CIProduct(id: "p2", name: "other", productType: "APP", appID: nil, appName: nil, bundleID: nil),
            ],
            runs: [
                run(395, workflow: "w1", name: "Public archive", created: date(10, 9, 11), status: .failed),
                run(394, workflow: "w1", name: "Public archive", created: date(10, 8, 16)),
                run(393, workflow: "w1", name: "Public archive", created: date(10, 8, 10), branch: "develop"),
                run(371, workflow: "w2", name: "Beta testing", created: date(10, 8, 12), pullRequest: 212, title: "Ma semaine"),
                run(5, product: "p2", workflow: "w9", name: "Default", created: date(10, 8, 9), branch: "release"),
            ],
            actionsByRunID: [
                "r395": [CIBuildAction(
                    id: "a395", buildRunID: "r395", name: "Archive", actionType: .archive, startedDate: date(10, 9, 11),
                    finishedDate: date(10, 9, 11, 6), executionProgress: .complete, completionStatus: .failed, isRequiredToPass: true
                )],
            ],
            workflows: workflows,
            xcodeVersions: [
                CIXcodeVersion(id: "x1", name: "Xcode 26.4", version: "26.4"),
                CIXcodeVersion(id: "x2", name: "Xcode 27.1", version: "27.1"),
                CIXcodeVersion(id: "x3", name: "Xcode 27.2 beta 2", version: "27.2"),
            ]
        )
    }

    private var ledger: UsageLedger {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(
                builds: [
                    BilledBuild(product: "realmotivation", buildNumber: 394, workflow: "Public archive", startedAt: date(10, 8, 16), minutes: 30),
                    BilledBuild(product: "realmotivation", buildNumber: 393, workflow: "Public archive", startedAt: date(10, 8, 10), minutes: 11),
                    BilledBuild(product: "realmotivation", buildNumber: 371, workflow: "Beta testing", startedAt: date(10, 8, 12), minutes: 17),
                    BilledBuild(product: "other", buildNumber: 5, workflow: "Default", startedAt: date(10, 8, 9), minutes: 28),
                ],
                coverage: DateInterval(start: date(9, 9), end: date(10, 9))
            ),
            fileName: "usage.csv", modifiedAt: date(10, 9, 8), importedAt: date(10, 9, 8)
        )
        return ledger
    }

    private func summary(now: Date? = nil) -> UsageSummary {
        UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now ?? self.now, calendar: calendar)
    }

    private func model(summary: UsageSummary?, details: [String: CIWorkflow] = [:], open: [PullRequestReference]? = nil, now: Date? = nil) -> AppOverviewModel? {
        AppOverviewModel(productID: "p1", snapshot: snapshot, details: details, summary: summary, openPullRequests: open, now: now ?? self.now, calendar: calendar)
    }

    @Test func theAppIsNamedByItsStoreNameAndKeyedByItsProductName() throws {
        let model = try #require(model(summary: summary()))

        #expect(model.displayName == "Crossfit Hyrox Tracker")
        #expect(model.productKey == "realmotivation")
        #expect(model.repository == "guikbsx/realmotivation", "the first workflow that names its repository")
    }

    @Test func anAppTheSnapshotDoesNotKnowHasNoOverview() {
        #expect(AppOverviewModel(productID: "nope", snapshot: snapshot, summary: summary(), now: now, calendar: calendar) == nil)
    }

    @Test func theCycleIsTheAppsShareOfThePlanAndOfWhatTheAccountUsed() throws {
        let summary = summary()
        let cycle = try #require(model(summary: summary)?.cycle)

        #expect(cycle.billedMinutes == 58)
        #expect(cycle.estimatedMinutes > 0, "#395 is not in the export yet")
        #expect(cycle.quotaMinutes == 1500)
        #expect(abs(cycle.accountMinutes - (cycle.totalMinutes + 28)) < 0.001)
        #expect(abs(cycle.fractionOfPlan - cycle.totalMinutes / 1500) < 0.0001)
        #expect(abs((cycle.shareOfUsed ?? 0) - cycle.totalMinutes / (cycle.totalMinutes + 28)) < 0.0001)
        #expect(cycle.hasEstimates && !cycle.isMeasuring)

        let elapsed = now.timeIntervalSince(summary.cycle.start)
        #expect(abs((cycle.projectedMinutes ?? 0) - cycle.totalMinutes / elapsed * summary.cycle.duration) < 0.001)
    }

    @Test func aCycleYoungerThanADayGivesNoProjection() throws {
        let early = date(10, 8, 10, 30)
        let cycle = try #require(model(summary: summary(now: early), now: early)?.cycle)

        #expect(cycle.projectedMinutes == nil)
    }

    @Test func theBarHasOneSliceByWorkflowThenTheOtherApps() throws {
        let cycle = try #require(model(summary: summary())?.cycle)

        #expect(cycle.segments.map(\.workflow) == ["Public archive", "Beta testing", nil])
        #expect(cycle.segments[1].minutes == 17 && cycle.segments[2].minutes == 28)
        #expect(abs(cycle.segments[0].minutes - (41 + cycle.estimatedMinutes)) < 0.001)
        #expect(cycle.segments[0].shade > cycle.segments[1].shade, "a further workflow is lighter")
    }

    @Test func everyWorkflowOfTheAppHasARowEvenWithoutABuild() throws {
        let rows = try #require(model(summary: summary())?.workflows)

        #expect(rows.map(\.name) == ["Public archive", "Beta testing", "Internal archive"], "costliest first; the other app's workflow is left out")
        #expect(rows[2].lastRun == nil && rows[2].successRate == nil && rows[2].cycleMinutes == 0 && rows[2].cycleBuilds == 0)
    }

    @Test func aRowTellsItsLastBuildItsTrendsAndItsMinutes() throws {
        let rows = try #require(model(summary: summary())?.workflows)
        let archive = rows[0]
        let beta = rows[1]

        #expect(archive.lastRun?.number == 395 && archive.lastStatus == .failed)
        #expect(abs((archive.successRate ?? 0) - 2.0 / 3.0) < 0.0001)
        #expect(archive.medianDuration == 600)
        #expect(archive.cycleBuilds == 3 && archive.isEstimated)
        #expect(beta.lastRun?.number == 371 && beta.lastStatus == .succeeded)
        #expect(beta.cycleMinutes == 17 && beta.cycleBuilds == 1 && !beta.isEstimated)
    }

    @Test func aRowTellsWhenItsWorkflowIsPausedOrOnAnOlderXcode() throws {
        let rows = try #require(model(summary: summary())?.workflows)

        #expect(rows[0].xcodeVersion == "Xcode 26.4")
        #expect(rows[0].xcodeWarning == XcodeVersionCheck.Warning(current: "Xcode 26.4", latest: "Xcode 27.1"), "the beta is not the newest public one")
        #expect(rows[1].xcodeVersion == "Xcode 27.1" && rows[1].xcodeWarning == nil)
        #expect(!rows[0].isPaused && rows[2].isPaused)
    }

    @Test func aScheduleComesBeforeTheConditionThatStartsTheWorkflow() throws {
        let rows = try #require(model(summary: summary())?.workflows)

        #expect(rows[0].next == .onChange(.branch, source: "main"))
        #expect(rows[1].next == .scheduled(date(10, 12, 6), minutes: 17), "next Monday at six, at what its build of the cycle cost")
        #expect(rows[2].next == nil, "a paused workflow starts nothing")
    }

    @Test func theConditionsReadForTheWorkflowsSheetWinOverTheSyncs() throws {
        var richer = workflows[0]
        richer.startConditions = CIStartConditions(tags: CIPatterns(isAllMatch: true, patterns: []))

        let rows = try #require(model(summary: summary(), details: ["w1": richer])?.workflows)

        #expect(rows[0].next == .onChange(.tag, source: nil))
    }

    @Test func theTotalCoversEveryBuildOfTheApp() throws {
        let model = try #require(model(summary: summary()))

        #expect(model.total.successRate == 0.75)
        #expect(model.total.medianDuration == 600)
        #expect(model.total.cycleMinutes == model.cycle?.totalMinutes)
        #expect(model.total.isEstimated)
        #expect(model.total.upcomingMinutes == 68, "four Mondays before the reset, 17 minutes each")
    }

    @Test func theBarsAreTheAppsFinishedBuildsOldestFirst() throws {
        let model = try #require(model(summary: summary()))

        #expect(model.bars.map(\.number) == [393, 371, 394, 395])
        #expect(model.bars.map(\.succeeded) == [true, true, true, false])
        #expect(model.medianQueueWait == 20)
    }

    @Test func theReferencesAreTheAppsOwnNewestFirst() throws {
        let known = try #require(model(summary: summary()))
        let closed = try #require(model(summary: summary(), open: []))

        #expect(known.references.map(\.title) == ["main", "#212 Ma semaine", "develop"], "the other app's branch is left out")
        #expect(known.references.first?.lastRun.number == 395)
        #expect(closed.references.map(\.title) == ["main", "develop"], "a pull request Apple no longer lists is closed")
    }

    @Test func theCostliestBuildIsTheAppsOwn() throws {
        let model = try #require(model(summary: summary()))

        #expect(model.costliestBuild?.buildNumber == 394 && model.costliestBuild?.minutes == 30 && model.costliestBuild?.isEstimated == false)
        #expect(model.costliestRunID == "r394")
    }

    @Test func theTestFlightBuildIsTheNewestSuccessOfAWorkflowThatShips() throws {
        let model = try #require(model(summary: summary()))

        #expect(model.testFlightRun?.number == 394, "#395 failed, and Beta testing does not hand anything to TestFlight")
    }

    @Test func withoutAPlanTheTableStandsWithoutMinutes() throws {
        let model = try #require(model(summary: nil))

        #expect(model.cycle == nil)
        #expect(model.workflows.count == 3 && model.workflows.allSatisfy { $0.cycleMinutes == nil })
        #expect(model.workflows.first?.name == "Public archive", "the one that built last comes first")
        #expect(model.total.cycleMinutes == nil && model.total.upcomingMinutes == nil)
        #expect(model.total.successRate == 0.75)
        #expect(model.costliestBuild == nil)
    }
}
