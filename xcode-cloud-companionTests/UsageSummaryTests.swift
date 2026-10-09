import Foundation
import Testing
@testable import XcodeCloudCompanion

struct UsageSummaryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private var now: Date { date(10, 9, 12) }
    private var plan: UsagePlan { UsagePlan(hours: 25, resetAnchor: date(11, 7, 14, 48)) }

    private func run(_ number: Int, product: String = "p1", workflow: String = "WF", created: Date, running: Bool = false) -> CIBuildRun {
        CIBuildRun(
            id: "run-\(number)", productID: product, number: number, createdDate: created, startedDate: created, finishedDate: nil,
            executionProgress: running ? .running : .complete, completionStatus: running ? nil : .succeeded,
            startReason: nil, workflowID: nil, workflowName: workflow, sourceBranchOrTag: nil
        )
    }

    private func actions(_ runID: String, start: Date, minutes: Double?) -> [CIBuildAction] {
        [CIBuildAction(
            id: "\(runID)-a", buildRunID: runID, name: nil, actionType: .test, startedDate: start,
            finishedDate: minutes.map { start.addingTimeInterval($0 * 60) },
            executionProgress: minutes == nil ? .running : .complete, completionStatus: nil, isRequiredToPass: nil
        )]
    }

    private func billed(_ number: Int, product: String = "AppOne", workflow: String = "WF", at startedAt: Date, minutes: Int) -> BilledBuild {
        BilledBuild(product: product, buildNumber: number, workflow: workflow, startedAt: startedAt, minutes: minutes)
    }

    /// #10 and #11 are billed (50 min for 20 min of actions: ratio 2.5); #12 finished and #13 still running are not exported yet.
    /// The test actions here have no per-device results and are given up on, so their wall clock stands in for them.
    private func givenUp(_ snapshot: BuildSnapshot) -> BuildSnapshot {
        var snapshot = snapshot
        for action in snapshot.actionsByRunID.values.joined() {
            snapshot.testResultAttempts[action.id] = BuildSnapshot.maximumTestResultAttempts
        }
        return snapshot
    }

    private var snapshot: BuildSnapshot {
        givenUp(BuildSnapshot(
            products: [CIProduct(id: "p1", name: "AppOne", productType: "APP", appID: nil, appName: nil, bundleID: nil)],
            runs: [
                run(13, workflow: "Other", created: date(10, 9, 11, 50), running: true),
                run(12, created: date(10, 9, 9)),
                run(11, created: date(10, 8, 12)),
                run(10, created: date(10, 8, 10)),
            ],
            actionsByRunID: [
                "run-10": actions("run-10", start: date(10, 8, 10), minutes: 10),
                "run-11": actions("run-11", start: date(10, 8, 12), minutes: 10),
                "run-12": actions("run-12", start: date(10, 9, 9), minutes: 4),
                "run-13": actions("run-13", start: date(10, 9, 11, 50), minutes: nil),
            ]
        ))
    }

    private var ledger: UsageLedger {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(
                builds: [
                    billed(10, at: date(10, 8, 10), minutes: 20),
                    billed(11, at: date(10, 8, 12), minutes: 30),
                    billed(5, product: "AppTwo", at: date(10, 1, 10), minutes: 40),
                ],
                coverage: DateInterval(start: date(9, 9), end: date(10, 9))
            ),
            fileName: "usage.csv", modifiedAt: date(10, 9, 8), importedAt: date(10, 9, 8)
        )
        return ledger
    }

    @Test func billedMinutesComeFromTheExportAndTheRestIsEstimatedApart() {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)

        #expect(summary.cycle == DateInterval(start: date(10, 7, 14, 48), end: date(11, 7, 14, 48)))
        #expect(summary.billedMinutes == 50)
        #expect(abs(summary.estimatedMinutes - (4 * 2.5 + 10 * 2.5)) < 0.001)
        #expect(summary.estimatedBuildCount == 2)
        #expect(abs(summary.usedMinutes - 85) < 0.001)
        #expect(abs(summary.availableMinutes - (1500 - 85)) < 0.001)
        #expect(summary.resetDate == date(11, 7, 14, 48))
        #expect(!summary.isImportStale)
    }

    @Test func buildsCountInTheCycleOfTheirDate() {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)

        #expect(summary.byApp.map(\.product) == ["AppOne"])
        #expect(summary.daily.count == 30)
        #expect(summary.daily.last?.day == date(10, 9))
        #expect(abs(summary.todayMinutes - 35) < 0.001)
        #expect(summary.daily.first { $0.day == date(10, 1) }?.billedMinutes == 40)
        #expect(abs(summary.last30DaysMinutes - 125) < 0.001)
        #expect(summary.buildsLast30Days == 5)
    }

    @Test func withoutAnyExportEverythingIsEstimatedAtFaceValueAndFlagged() {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: UsageLedger(), plan: plan, now: now, calendar: calendar)

        #expect(summary.billedMinutes == 0)
        #expect(abs(summary.estimatedMinutes - (10 + 10 + 4 + 10)) < 0.001)
        #expect(summary.estimatedBuildCount == 4)
        #expect(summary.isImportStale)
    }

    @Test func anOldExportIsFlagged() {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: date(10, 12, 9), calendar: calendar)

        #expect(summary.isImportStale)
    }

    @Test func workflowsWithoutMeasuredActionsNeverDivideByZero() {
        let product = ["p1": "AppOne"]
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(builds: [billed(1, at: date(10, 8), minutes: 5)], coverage: DateInterval(start: date(10, 1), end: date(10, 9))),
            fileName: "u.csv", modifiedAt: now, importedAt: now
        )
        let snapshot = BuildSnapshot(runs: [run(1, created: date(10, 8))], actionsByRunID: [:])

        let ratios = WorkflowRatios(snapshot: snapshot, ledger: ledger, productNames: product, now: now)

        #expect(ratios.ratio(product: "AppOne", workflow: "WF") == 1)
    }

    @Test func eachWorkflowLearnsItsOwnRatioThenFallsBackToTheGlobalOne() {
        let ratios = WorkflowRatios(snapshot: snapshot, ledger: ledger, productNames: ["p1": "AppOne"], now: now)

        #expect(ratios.ratio(product: "AppOne", workflow: "WF") == 2.5)
        #expect(ratios.ratio(product: "AppOne", workflow: "Unknown") == 2.5)
    }

    @Test func aBuildBeforeTheResetBelongsToThePreviousCycle() {
        var snapshot = snapshot
        snapshot.runs.append(run(9, created: date(10, 7, 14, 30)))
        snapshot.actionsByRunID["run-9"] = actions("run-9", start: date(10, 7, 14, 30), minutes: 30)
        snapshot = givenUp(snapshot)

        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)

        #expect(summary.estimatedBuildCount == 2)
        #expect(abs(summary.usedMinutes - 85) < 0.001)
    }

    @Test func thePaceProjectsTheEndOfTheCycleAndWhenTheQuotaRunsOut() throws {
        let calm = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)
        #expect(try #require(calm.projectedMinutes) < 1500)
        #expect(calm.exhaustionDate == nil)

        var heavy = ledger
        heavy.merge(UsageExport(builds: [billed(20, at: date(10, 9, 8), minutes: 600)], coverage: DateInterval(start: date(10, 9), duration: 0)), fileName: "b.csv", modifiedAt: now, importedAt: now)
        let busy = UsageCalculator.summary(snapshot: snapshot, ledger: heavy, plan: plan, now: now, calendar: calendar)
        #expect(try #require(busy.projectedMinutes) > 1500)
        let exhaustion = try #require(busy.exhaustionDate)
        #expect(exhaustion > now && exhaustion < busy.resetDate)
    }

    @Test func aYoungCycleHasNoPaceYet() {
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: date(10, 7, 20), calendar: calendar)

        #expect(summary.projectedMinutes == nil)
    }

    @Test func anExhaustedQuotaHasNothingLeft() {
        var over = ledger
        over.merge(UsageExport(builds: [billed(30, at: date(10, 9, 8), minutes: 2000)], coverage: DateInterval(start: date(10, 9), duration: 0)), fileName: "c.csv", modifiedAt: now, importedAt: now)

        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: over, plan: plan, now: now, calendar: calendar)

        #expect(summary.availableMinutes == 0)
        #expect(summary.fractionUsed > 1)
        #expect(summary.exhaustionDate == now)
    }
}
