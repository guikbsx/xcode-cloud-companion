import AppKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200)

private func json(_ string: String) -> MockTransport.Reply {
    MockTransport.Reply(body: Data(string.utf8))
}

/// An API with `count` finished builds, run N created N hours ago, each with one test action `t-N` and one archive.
private func apiWithBuilds(count: Int, testResults: @escaping @Sendable (URLRequest) -> MockTransport.Reply) -> @Sendable (URLRequest) -> MockTransport.Reply {
    return { request in
        let path = request.url?.path() ?? ""
        switch path {
        case "/v1/ciProducts":
            return json(#"{"data": [{"type": "ciProducts", "id": "p", "attributes": {"name": "App"}}], "links": {}}"#)
        case "/v1/ciProducts/p/workflows":
            return json(#"{"data": [], "links": {}}"#)
        case "/v1/ciProducts/p/buildRuns":
            let runs = (1...count).map { n -> String in
                let created = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(n) * 3600))
                return #"{"type": "ciBuildRuns", "id": "run-\#(n)", "attributes": {"number": \#(n), "createdDate": "\#(created)", "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}}"#
            }
            return json(#"{"data": [\#(runs.joined(separator: ","))], "links": {}}"#)
        default:
            if path.hasSuffix("/actions") {
                let n = path.dropFirst("/v1/ciBuildRuns/run-".count).prefix { $0.isNumber }
                let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(Int(n) ?? 0) * 3600))
                return json(#"{"data": [{"type": "ciBuildActions", "id": "t-\#(n)", "attributes": {"actionType": "TEST", "startedDate": "\#(start)", "finishedDate": "\#(start)", "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}}], "links": {}}"#)
            }
            if path.hasSuffix("/testResults") {
                return testResults(request)
            }
            return json(#"{"data": [], "links": {}}"#)
        }
    }
}

private let oneDevice = #"{"data": [{"type": "ciTestResults", "id": "r", "attributes": {"destinationTestResults": [{"deviceName": "iPhone", "osVersion": "27", "status": "SUCCESS", "duration": 60}]}}], "links": {}}"#

struct TestResultAttemptsTests {
    @Test func testResultsAreFetchedNewestBuildFirst() async throws {
        let transport = MockTransport(reply: apiWithBuilds(count: 14) { _ in json(oneDevice) })
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let snapshot = try await synchronizer.sync(from: .empty, now: now)

        let fetched = Set(await transport.requests.compactMap { $0.url?.path() }.filter { $0.hasSuffix("/testResults") }
            .map { $0.split(separator: "/")[2] })
        #expect(fetched.count == 12)
        #expect(fetched.contains("t-1") && fetched.contains("t-12"))
        #expect(!fetched.contains("t-13") && !fetched.contains("t-14"))
        #expect(BuildSynchronizer.pendingTestResultCount(in: snapshot) == 2)
    }

    @Test func aSecondPassFinishesTheRest() async throws {
        let transport = MockTransport(reply: apiWithBuilds(count: 14) { _ in json(oneDevice) })
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))
        let first = try await synchronizer.sync(from: .empty, now: now)

        let second = try await synchronizer.sync(from: first, now: now)

        #expect(second.testDevicesByActionID.count == 14)
        #expect(BuildSynchronizer.pendingTestResultCount(in: second) == 0)
        #expect(second.testResultAttempts.isEmpty)
    }

    @Test func anActionApplesRefusesIsGivenUpOnAfterThreeAttempts() async throws {
        let transport = MockTransport(reply: apiWithBuilds(count: 2) { _ in MockTransport.Reply(status: 500) })
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))
        var snapshot = BuildSnapshot.empty

        for expected in 1...3 {
            snapshot = try await synchronizer.sync(from: snapshot, now: now)
            #expect(snapshot.testResultAttempts["t-1"] == expected)
        }
        #expect(BuildSynchronizer.pendingTestResultCount(in: snapshot) == 0)

        let before = await transport.requests.count
        snapshot = try await synchronizer.sync(from: snapshot, now: now)
        let asked = await transport.requests.dropFirst(before).compactMap { $0.url?.path() }.filter { $0.hasSuffix("/testResults") }
        #expect(asked.isEmpty)
    }

    @Test func aRateLimitCostsNoAttempt() async throws {
        let transport = MockTransport(reply: apiWithBuilds(count: 2) { _ in MockTransport.Reply(status: 429) })
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let snapshot = try await synchronizer.sync(from: .empty, now: now)

        #expect(snapshot.testResultAttempts.isEmpty)
        #expect(BuildSynchronizer.pendingTestResultCount(in: snapshot) == 2)
    }

    @Test func aSuccessfulFetchForgetsEarlierFailures() async throws {
        let counter = Counter()
        let transport = MockTransport(reply: apiWithBuilds(count: 1) { _ in counter.next() == 1 ? MockTransport.Reply(status: 500) : json(oneDevice) })
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let failed = try await synchronizer.sync(from: .empty, now: now)
        #expect(failed.testResultAttempts["t-1"] == 1)

        let measured = try await synchronizer.sync(from: failed, now: now)
        #expect(measured.testResultAttempts.isEmpty)
        #expect(measured.testDevicesByActionID["t-1"]?.count == 1)
    }

    @Test func oldCachesWithoutAttemptsStillLoad() throws {
        let snapshot = try JSONDecoder().decode(BuildSnapshot.self, from: Data(#"{"products": [], "runs": []}"#.utf8))

        #expect(snapshot.testResultAttempts.isEmpty)
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

struct MeasurementProgressTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private var plan: UsagePlan { UsagePlan(hours: 25, resetAnchor: now.addingTimeInterval(20 * 86_400)) }

    private func run(_ number: Int, hoursAgo: Double, product: String = "p") -> CIBuildRun {
        let created = now.addingTimeInterval(-hoursAgo * 3600)
        return CIBuildRun(
            id: "run-\(number)", productID: product, number: number, createdDate: created, startedDate: created, finishedDate: created.addingTimeInterval(600),
            executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: nil, workflowName: "WF", sourceBranchOrTag: nil
        )
    }

    private func testAction(_ number: Int, hoursAgo: Double) -> [CIBuildAction] {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        return [CIBuildAction(
            id: "t-\(number)", buildRunID: "run-\(number)", name: nil, actionType: .test, startedDate: start, finishedDate: start.addingTimeInterval(600),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: nil
        )]
    }

    private func snapshot(runs: [Int], measured: Set<Int> = [], attempts: [Int: Int] = [:]) -> BuildSnapshot {
        var snapshot = BuildSnapshot(products: [CIProduct(id: "p", name: "App", productType: nil, appID: nil, appName: nil, bundleID: nil)])
        for number in runs {
            snapshot.runs.append(run(number, hoursAgo: Double(number)))
            snapshot.actionsByRunID["run-\(number)"] = testAction(number, hoursAgo: Double(number))
            if measured.contains(number) {
                snapshot.testDevicesByActionID["t-\(number)"] = [CITestDeviceRun(deviceName: "iPhone", osVersion: "27", testCount: 1, failedCount: 0, totalSeconds: 120)]
            }
            if let count = attempts[number] { snapshot.testResultAttempts["t-\(number)"] = count }
        }
        return snapshot
    }

    private func summary(_ snapshot: BuildSnapshot, ledger: UsageLedger = UsageLedger()) -> UsageSummary {
        UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now, calendar: calendar)
    }

    @Test func buildsWaitingForTheirTestResultsAreCountedAndLeftOutOfTheFigures() {
        let measuring = summary(snapshot(runs: [1, 2, 3, 4], measured: [1]))

        #expect(measuring.measurement.totalActions == 4)
        #expect(measuring.measurement.measuredActions == 1)
        #expect(measuring.measurement.pendingActions == 3)
        #expect(measuring.measurement.pendingBuilds == 3)
        #expect(measuring.measurement.isMeasuring)
        // Only the measured build counts: 1 device × (2 min + 4.5 min preparation).
        #expect(abs(measuring.estimatedMinutes - 6.5) < 0.001)
        #expect(measuring.measurement.fractionDone == 0.25)
    }

    @Test func theWaitIsOneMinutePerBatchOfTwelve() {
        #expect(MeasurementProgress(totalActions: 40, measuredActions: 4).minutesLeft == 3)
        #expect(MeasurementProgress(totalActions: 40, measuredActions: 28).minutesLeft == 1)
        #expect(MeasurementProgress(totalActions: 40, measuredActions: 40).minutesLeft == 0)
    }

    @Test func onceEveryBuildIsMeasuredTheStateEnds() {
        let done = summary(snapshot(runs: [1, 2], measured: [1, 2]))

        #expect(!done.measurement.isMeasuring)
        #expect(done.measurement.fractionDone == 1)
    }

    @Test func buildsApplesAlreadyBilledNeverWaitForMeasurement() {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(builds: [BilledBuild(product: "App", buildNumber: 2, workflow: "WF", startedAt: now.addingTimeInterval(-7200), minutes: 30)], coverage: DateInterval(start: now, duration: 0)),
            fileName: "u.csv", modifiedAt: now, importedAt: now
        )

        let result = summary(snapshot(runs: [2]), ledger: ledger)

        #expect(!result.measurement.isMeasuring)
        #expect(result.measurement.totalActions == 0)
        #expect(result.billedMinutes == 30)
    }

    @Test func buildsOlderThanTheCycleDoNotKeepTheMenuMeasuring() {
        // 30 days ago is before the cycle that started 10 days ago.
        let old = summary(snapshot(runs: [1000]))

        #expect(!old.measurement.isMeasuring)
    }

    @Test func anActionGivenUpOnEndsTheStateAndIsReported() {
        let result = summary(snapshot(runs: [1, 2], measured: [1], attempts: [2: 3]))

        #expect(!result.measurement.isMeasuring)
        #expect(result.measurement.unmeasurableActions == 1)
        #expect(result.measurement.unmeasurableBuilds == 1)
        // Without results the build is estimated from its wall clock instead of waiting forever.
        #expect(result.estimatedBuildCount == 2)
    }
}

@MainActor
struct MeasuringMenuTests {
    private func state(measuring: Bool, syncing: Bool = false, startedSecondsAgo: Double? = nil) -> StatusMenuState {
        let plan = UsagePlan(hours: 25, resetAnchor: now.addingTimeInterval(20 * 86_400))
        var summary = UsageCalculator.summary(snapshot: .empty, ledger: UsageLedger(), plan: plan, now: now)
        summary.measurement = measuring ? MeasurementProgress(totalActions: 36, measuredActions: 14) : MeasurementProgress(totalActions: 36, measuredActions: 36)
        return StatusMenuState(
            needsAPIKey: false, summary: summary, lastSync: now, syncStartedAt: startedSecondsAgo.map { now.addingTimeInterval(-$0) },
            isSyncing: syncing, errorMessage: nil, now: now
        )
    }

    @Test func theMenuOpensOnTheProgressBlockWhileMeasuring() {
        let items = StatusMenuBuilder.items(for: state(measuring: true), actions: StatusMenuActions())

        #expect(items.first?.view != nil)
        #expect(items.dropFirst().first?.isSeparatorItem == true)
        #expect(items.filter { $0.view != nil }.count == 2)
    }

    @Test func noProgressBlockOnceMeasured() {
        let items = StatusMenuBuilder.items(for: state(measuring: false), actions: StatusMenuActions())

        #expect(items.filter { $0.view != nil }.count == 1)
    }

    @Test func theMenuBarShowsAnEllipsisInsteadOfAFalsePercentage() {
        #expect(StatusMenuBuilder.buttonTitle(for: state(measuring: true).summary) == "…")
        #expect(StatusMenuBuilder.buttonTitle(for: state(measuring: false).summary) == UsageFormat.percent(0))
    }

    @Test func theStatusLineSaysWhenALongSyncStarted() {
        #expect(StatusMenuBuilder.statusLine(for: state(measuring: true, syncing: true, startedSecondsAgo: 20)) == "Updating…")
        #expect(StatusMenuBuilder.statusLine(for: state(measuring: true, syncing: true, startedSecondsAgo: 130)).hasPrefix("Syncing · started"))
    }

    @Test func appBadgesTrailOffWhileMeasuring() {
        let product = CIProduct(id: "p", name: "Alpha", productType: nil, appID: nil, appName: nil, bundleID: nil)
        let run = CIBuildRun(
            id: "r", productID: "p", number: 1, createdDate: now, startedDate: now, finishedDate: now, executionProgress: .complete, completionStatus: .succeeded,
            startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
        let snapshot = BuildSnapshot(products: [product], runs: [run])
        var summary = state(measuring: true).summary
        summary?.byApp = [AppUsage(product: "Alpha", billedMinutes: 42)]

        let items = AppBuildsMenu.items(snapshot: snapshot, summary: summary, now: now) { _ in }
        #expect(items.first { $0.title.hasSuffix("Alpha") }?.badge?.stringValue == "42m…")

        summary?.byApp = []
        let empty = AppBuildsMenu.items(snapshot: snapshot, summary: summary, now: now) { _ in }
        #expect(empty.first { $0.title.hasSuffix("Alpha") }?.badge?.stringValue == "…")
    }
}
