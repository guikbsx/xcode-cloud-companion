import Foundation
import Testing
@testable import XcodeCloudCompanion

struct WorkflowCostBreakdownTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? .distantPast
    }

    private var now: Date { date(9, 12) }
    private var plan: UsagePlan { UsagePlan(hours: 25, resetAnchor: date(7, 14)) }

    private func run(_ number: Int, workflow: String? = "CI", on day: Int = 8) -> CIBuildRun {
        CIBuildRun(
            id: "run-\(number)", productID: "p1", number: number, createdDate: date(day), startedDate: date(day), finishedDate: date(day, 11),
            executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: workflow, sourceBranchOrTag: nil
        )
    }

    private func action(_ id: String, run number: Int, _ type: CIActionType, minutes: Double) -> CIBuildAction {
        CIBuildAction(
            id: id, buildRunID: "run-\(number)", name: nil, actionType: type, startedDate: date(8), finishedDate: date(8).addingTimeInterval(minutes * 60),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true
        )
    }

    private func device(_ name: String, seconds: Double, failed: Int = 0) -> CITestDeviceRun {
        CITestDeviceRun(deviceName: name, osVersion: "27.0", testCount: 10, failedCount: failed, totalSeconds: seconds)
    }

    /// #10 is billed 30 min for 28 modelled (build 4, two devices of 5 min, one rerun, two preparations of 4.5); #12 is not exported yet.
    private var snapshot: BuildSnapshot {
        BuildSnapshot(
            products: [CIProduct(id: "p1", name: "AppOne", productType: "APP", appID: nil, appName: "App One, the Store name", bundleID: nil)],
            runs: [run(12), run(10)],
            actionsByRunID: [
                "run-10": [action("b10", run: 10, .build, minutes: 4), action("t10", run: 10, .test, minutes: 12)],
                "run-12": [action("b12", run: 12, .build, minutes: 4), action("a12", run: 12, .archive, minutes: 6)],
            ],
            testDevicesByActionID: ["t10": [device("iPhone 17 Pro", seconds: 300, failed: 1), device("iPad Pro 13", seconds: 300)]]
        )
    }

    private func ledger(_ builds: [BilledBuild]) -> UsageLedger {
        var ledger = UsageLedger()
        guard !builds.isEmpty else { return ledger }
        ledger.merge(
            UsageExport(builds: builds, coverage: DateInterval(start: date(1), end: date(9))),
            fileName: "usage.csv", modifiedAt: date(9, 8), importedAt: date(9, 8)
        )
        return ledger
    }

    private var billedTen: BilledBuild { BilledBuild(product: "AppOne", buildNumber: 10, workflow: "CI", startedAt: date(8), minutes: 30) }

    private func breakdown(_ snapshot: BuildSnapshot, _ ledger: UsageLedger, workflow: String = "CI") -> WorkflowCostBreakdown {
        WorkflowCostBreakdown(product: "AppOne", workflow: workflow, snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    @Test func theTotalIsTheOverviewsOwnFigure() throws {
        let ledger = ledger([billedTen])
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)
        let overview = try #require(summary.byWorkflow.first { $0.workflow == "CI" })

        let breakdown = breakdown(snapshot, ledger)

        #expect(close(breakdown.totalMinutes, overview.totalMinutes))
        #expect(close(breakdown.billedMinutes, overview.billedMinutes))
        #expect(close(breakdown.estimatedMinutes, overview.estimatedMinutes))
        #expect(breakdown.buildCount == overview.buildCount)
        #expect(breakdown.estimatedBuildCount == 1)
        #expect(close(breakdown.items.reduce(0) { $0 + $1.minutes }, breakdown.totalMinutes))
        #expect(close(breakdown.items.reduce(0) { $0 + $1.share }, 1))
        #expect(breakdown.isEstimated)
    }

    @Test func eachItemGetsItsShareOfEachBuild() {
        let breakdown = breakdown(snapshot, ledger([billedTen]))
        // #10: 30 billed minutes over 28 modelled ones; #12: 10 modelled minutes at the same ratio.
        let scale = 30.0 / 28.0

        #expect(close(breakdown.minutes(.build), (4 + 4) * scale))
        #expect(close(breakdown.minutes(.tests(destination: "iPhone 17 Pro")), 5 * scale))
        #expect(close(breakdown.minutes(.tests(destination: "iPad Pro 13")), 5 * scale))
        #expect(close(breakdown.minutes(.reruns), 5 * scale))
        #expect(close(breakdown.minutes(.preparation), 9 * scale))
        #expect(close(breakdown.minutes(.archive), 6 * scale))
        #expect(breakdown.minutes(.other) == 0)
        #expect(breakdown.destinationCount == 2)
        #expect(breakdown.unsplitTestActions == 0)
        #expect(breakdown.items.first?.kind == .preparation)
    }

    @Test func theFindingsOnlySayWhatTheFiguresCarry() {
        let scale = 30.0 / 28.0
        let findings = breakdown(snapshot, ledger([billedTen])).findings

        #expect(findings.count == 2)
        guard case .destinations(let count, let share)? = findings.first, case .reruns(let minutes)? = findings.last else {
            Issue.record("Unexpected findings: \(findings)")
            return
        }
        #expect(count == 2)
        #expect(close(share, 24.0 / 38.0))
        #expect(close(minutes, 5 * scale))
        #expect(WorkflowCostBreakdown.Finding.reruns(minutes: 5).text == "Tests rerun after a failure cost ~5 min this cycle.")
        #expect(WorkflowCostBreakdown.Finding.destinations(count: 4, share: 0.8).text == "4 test destinations: together, 80% of this workflow’s cost.")
        #expect(WorkflowCostBreakdown.Kind.tests(destination: "iPad Pro 13").title == "Tests · iPad Pro 13")
    }

    @Test func preparationIsCalledOutOnlyWhenItOutweighsTheTests() {
        var quick = snapshot
        quick.testDevicesByActionID["t10"] = [device("iPhone 17 Pro", seconds: 60)]

        let findings = breakdown(quick, ledger([])).findings

        #expect(findings == [.preparationOutweighsTests(preparationMinutes: 4.5, testMinutes: 1)])
        #expect(breakdown(quick, ledger([])).destinationCount == 1)
    }

    @Test func withoutAnExportEverythingIsAnEstimate() {
        let breakdown = breakdown(snapshot, ledger([]))

        #expect(breakdown.billedMinutes == 0)
        #expect(close(breakdown.estimatedMinutes, 28 + 10))
        #expect(breakdown.estimatedBuildCount == 2)
        #expect(breakdown.isEstimated)
    }

    @Test func aFullyBilledWorkflowIsExact() {
        let all = ledger([billedTen, BilledBuild(product: "AppOne", buildNumber: 12, workflow: "CI", startedAt: date(8), minutes: 11)])

        let breakdown = breakdown(snapshot, all)

        #expect(!breakdown.isEstimated)
        #expect(breakdown.totalMinutes == 41)
        #expect(close(breakdown.minutes(.archive), 11 * 6 / 10))
    }

    @Test func aTestActionGivenUpOnIsCountedWholeAndSaidSo() {
        var abandoned = snapshot
        abandoned.testDevicesByActionID = [:]
        abandoned.testResultAttempts = ["t10": BuildSnapshot.maximumTestResultAttempts]

        let breakdown = breakdown(abandoned, ledger([]))

        #expect(breakdown.unsplitTestActions == 1)
        #expect(close(breakdown.minutes(.testsNotSplit), 12))
        #expect(breakdown.destinationCount == 0)
        #expect(breakdown.findings.isEmpty)
    }

    @Test func aBuildStillWaitingForItsTestResultsIsLeftOutLikeInTheOverview() throws {
        var waiting = snapshot
        waiting.testDevicesByActionID = [:]
        let summary = UsageCalculator.summary(snapshot: waiting, ledger: ledger([]), plan: plan, now: now, calendar: calendar)

        let breakdown = breakdown(waiting, ledger([]))

        #expect(breakdown.buildCount == 1)
        #expect(close(breakdown.totalMinutes, try #require(summary.byWorkflow.first { $0.workflow == "CI" }).totalMinutes))
        #expect(breakdown.unsplitTestActions == 0)
    }

    @Test func aBilledBuildTheAppNoLongerHoldsGoesToOther() {
        let gone = BilledBuild(product: "AppOne", buildNumber: 3, workflow: "CI", startedAt: date(8), minutes: 20)

        let breakdown = breakdown(snapshot, ledger([billedTen, gone]))

        #expect(breakdown.minutes(.other) == 20)
        #expect(breakdown.buildCount == 3)
    }

    @Test func otherWorkflowsAndOtherCyclesStayOut() {
        var mixed = snapshot
        mixed.runs += [run(20, workflow: "Nightly"), run(21, workflow: nil), run(22, on: 2)]
        for number in [20, 21, 22] {
            mixed.actionsByRunID["run-\(number)"] = [action("b\(number)", run: number, .build, minutes: 7)]
        }

        #expect(close(breakdown(mixed, ledger([])).totalMinutes, 38))
        // With five successful builds known, the model bills a build for its shortest run: 4 min, not the 7 on the clock.
        #expect(close(breakdown(mixed, ledger([]), workflow: "Nightly").totalMinutes, 4))
        #expect(close(breakdown(mixed, ledger([]), workflow: "Other workflows").minutes(.build), 4))
    }

    @Test func theOverviewRowKeepsTheProductKeyUnderTheStoreName() throws {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger([billedTen]), plan: plan, now: now, calendar: calendar)

        let row = try #require(OverviewModel(summary: summary, palette: AppPalette(), displayNames: snapshot.displayNames).workflows.first)

        #expect(row.productKey == "AppOne")
        #expect(row.product == "App One, the Store name")
        #expect(row.id == "AppOne|CI")
    }
}
