import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let day = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private typealias Observation = TestHealthReport.Observation

private func sample(_ number: Int, commit: String? = nil, _ tests: [Observation]) -> TestHealthReport.Sample {
    TestHealthReport.Sample(runID: "run-\(number)", number: number, date: day.addingTimeInterval(Double(number) * 3600), commit: commit, tests: tests)
}

private func test(
    _ name: String, _ status: CITestStatus, class className: String = "CartTests", action: String = "Test - iOS", failedOn: [String] = [], seconds: [Double] = []
) -> Observation {
    Observation(actionName: action, className: className, name: name, status: status, failedDevices: failedOn, deviceSeconds: seconds)
}

struct TestHealthReportTests {
    @Test func aTestThatFailsThenPassesOnTheSameCommitIsFlaky() throws {
        let report = TestHealthReport(samples: [
            sample(1, commit: "aaa", [test("testCheckout", .failure, failedOn: ["iPhone 17 Pro"])]),
            sample(2, commit: "aaa", [test("testCheckout", .success)]),
            sample(3, commit: "bbb", [test("testCheckout", .success)]),
        ], eligibleBuilds: 9)

        let flaky = try #require(report.flaky.first)
        #expect(report.flaky.count == 1)
        #expect(flaky.name == "testCheckout" && flaky.className == "CartTests" && flaky.actionName == "Test - iOS")
        #expect(flaky.failures == 1 && flaky.runs == 3)
        #expect(flaky.lastFailureRunID == "run-1" && flaky.lastFailureNumber == 1)
        #expect(flaky.devices == ["iPhone 17 Pro"])
        #expect(flaky.flipsOnSameCommit && !flaky.differsBetweenDevices)
        #expect(report.analyzedBuilds == 3 && report.eligibleBuilds == 9)
    }

    @Test func aTestWhoseResultDiffersBetweenDevicesIsFlaky() throws {
        let report = TestHealthReport(samples: [
            sample(4, [test("testSync", .mixed, failedOn: ["iPad Pro 13"])]),
            sample(7, [test("testSync", .mixed, failedOn: ["iPhone 17", "iPad Pro 13"])]),
            sample(5, [test("testSync", .success)]),
        ], eligibleBuilds: 3)

        let flaky = try #require(report.flaky.first)
        #expect(flaky.differsBetweenDevices && !flaky.flipsOnSameCommit)
        #expect(flaky.failures == 2 && flaky.runs == 3)
        #expect(flaky.lastFailureRunID == "run-7")
        #expect(flaky.devices == ["iPad Pro 13", "iPhone 17"])
    }

    @Test func aTestThatAlwaysFailsOrChangesWithTheCommitIsNotFlaky() {
        let report = TestHealthReport(samples: [
            sample(1, commit: "aaa", [test("testBroken", .failure), test("testFixed", .failure), test("testNoCommit", .failure)]),
            sample(2, commit: "aaa", [test("testBroken", .failure), test("testFixed", .failure)]),
            sample(3, commit: "bbb", [test("testBroken", .failure), test("testFixed", .success)]),
            sample(4, commit: nil, [test("testNoCommit", .success), test("testSkipped", .skipped), test("testKnown", .expectedFailure)]),
        ], eligibleBuilds: 4)

        #expect(report.flaky.isEmpty)
    }

    @Test func theSameNameInAnotherClassOrActionIsAnotherTest() {
        let report = TestHealthReport(samples: [
            sample(1, commit: "aaa", [test("testTotal", .failure), test("testTotal", .success, class: "OrderTests"), test("testTotal", .success, action: "Test - macOS")]),
            sample(2, commit: "aaa", [test("testTotal", .failure), test("testTotal", .success, class: "OrderTests"), test("testTotal", .success, action: "Test - macOS")]),
        ], eligibleBuilds: 2)

        #expect(report.flaky.isEmpty)
    }

    @Test func flakyTestsComeMostFailuresFirst() {
        let report = TestHealthReport(samples: [
            sample(1, [test("testA", .mixed), test("testB", .mixed)]),
            sample(2, [test("testA", .success), test("testB", .mixed)]),
        ], eligibleBuilds: 2)

        #expect(report.flaky.map(\.name) == ["testB", "testA"])
    }

    @Test func theSlowestTestsAreRankedByTheirAverageTimePerDevice() throws {
        let report = TestHealthReport(samples: [
            sample(1, [test("testSlow", .success, seconds: [30, 50]), test("testQuick", .success, seconds: [1, 1]), test("testNoTime", .success)]),
            sample(2, [test("testSlow", .failure, seconds: [40]), test("testQuick", .success, seconds: [2])]),
        ], eligibleBuilds: 2)

        #expect(report.slowest.map(\.name) == ["testSlow", "testQuick"])
        let slow = try #require(report.slowest.first)
        #expect(slow.averageSecondsPerDevice == 40)
        #expect(abs(slow.share - 120.0 / 124.0) < 0.0001)
        #expect(abs((report.slowest.last?.averageSecondsPerDevice ?? 0) - 4.0 / 3.0) < 0.0001)
    }

    @Test func onlyTheTenSlowestAreKept() {
        let tests = (1...15).map { test("test\($0)", .success, seconds: [Double($0)]) }

        let report = TestHealthReport(samples: [sample(1, tests)], eligibleBuilds: 1)

        #expect(report.slowest.count == 10)
        #expect(report.slowest.first?.name == "test15")
    }
}

private func run(_ number: Int, workflow: String = "w1", progress: CIExecutionProgress = .complete, sha: String? = nil) -> CIBuildRun {
    CIBuildRun(
        id: "run-\(number)", productID: "p1", number: number, createdDate: day.addingTimeInterval(Double(number) * 3600), startedDate: nil, finishedDate: nil,
        executionProgress: progress, completionStatus: progress == .complete ? .succeeded : nil, startReason: nil, workflowID: workflow, workflowName: "CI",
        sourceBranchOrTag: nil, sourceCommit: sha.map { CISourceCommit(commitSha: $0, message: nil, authorName: nil, webURL: nil) }
    )
}

private func action(_ number: Int, _ type: CIActionType = .test, progress: CIExecutionProgress = .complete) -> CIBuildAction {
    CIBuildAction(
        id: "action-\(number)", buildRunID: "run-\(number)", name: "Test - iOS", actionType: type, startedDate: nil, finishedDate: nil,
        executionProgress: progress, completionStatus: nil, isRequiredToPass: true
    )
}

private func extras(_ number: Int, status: CITestStatus = .success, complete: Bool = true) -> BuildExtras {
    let result = CITestResult(
        id: "t\(number)", buildActionID: "action-\(number)", className: "CartTests", name: "testCheckout", status: status, message: nil, file: nil,
        devices: [
            CITestDeviceResult(deviceName: "iPhone 17 Pro", osVersion: "27.0", status: status == .mixed ? .failure : status, duration: 12),
            CITestDeviceResult(deviceName: "iPad Pro 13", osVersion: "27.0", status: .success, duration: 8),
        ]
    )
    return BuildExtras(testsByAction: ["action-\(number)": [result]], testsComplete: complete)
}

private let snapshot = BuildSnapshot(
    runs: [run(5, sha: "aaa"), run(4, sha: "aaa"), run(3), run(2, progress: .running), run(1, workflow: "other"), run(6)],
    actionsByRunID: [
        "run-6": [action(6, .build)], "run-5": [action(5)], "run-4": [action(4)], "run-3": [action(3)], "run-2": [action(2, progress: .running)], "run-1": [action(1)],
    ]
)

struct TestHealthReaderTests {
    private let cache = BuildExtrasCache(directory: FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)"))

    @Test func onlyFinishedBuildsOfTheWorkflowThatRanTestsAreEligible() {
        #expect(TestHealthReport.eligibleRuns(workflowID: "w1", in: snapshot).map(\.number) == [5, 4, 3])
        #expect(TestHealthReport.eligibleRuns(workflowID: "other", in: snapshot).map(\.number) == [1])
    }

    @Test func aBuildWhoseTestsAreNotAllLoadedIsNotASample() throws {
        #expect(TestHealthReport.sample(of: run(5), actions: [action(5)], extras: nil) == nil)
        #expect(TestHealthReport.sample(of: run(5), actions: [action(5)], extras: extras(5, complete: false)) == nil)

        let sample = try #require(TestHealthReport.sample(of: run(5, sha: "aaa"), actions: [action(5)], extras: extras(5, status: .mixed)))
        #expect(sample.commit == "aaa" && sample.number == 5)
        #expect(sample.tests == [Observation(
            actionName: "Test - iOS", className: "CartTests", name: "testCheckout", status: .mixed, failedDevices: ["iPhone 17 Pro"], deviceSeconds: [12, 8]
        )])
    }

    @Test func theReportIsReadFromWhatIsOnDiskAndSaysHowMuchThatIs() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5, status: .failure), runID: "run-5")
        await cache.save(extras(4), runID: "run-4")
        await cache.save(extras(1, status: .mixed), runID: "run-1")
        let reader = TestHealthReader(cache: cache)

        let report = await reader.report(workflowID: "w1", in: snapshot)

        #expect(report.analyzedBuilds == 2 && report.eligibleBuilds == 3)
        #expect(report.flaky.map(\.name) == ["testCheckout"])
        #expect(report.flaky.first?.flipsOnSameCommit == true)
        #expect(report.slowest.first?.averageSecondsPerDevice == 10)
        #expect(await reader.runsToAnalyze(workflowID: "w1", in: snapshot, limit: 10).map(\.number) == [3])
    }

    @Test func theNewestMissingBuildsAreAnalyzedFirstUpToTheLimit() async {
        let reader = TestHealthReader(cache: cache)

        #expect(await reader.runsToAnalyze(workflowID: "w1", in: snapshot, limit: 2).map(\.number) == [5, 4])
        #expect(await reader.report(workflowID: "w1", in: snapshot).analyzedBuilds == 0)
    }
}

@MainActor
struct WorkflowTestsModelTests {
    private let cache = BuildExtrasCache(directory: FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)"))

    private final class Loads {
        var runs: [Int] = []
        var remaining = 3_000
        var failure: String?
    }

    private func model(_ loads: Loads) -> WorkflowTestsModel {
        let cache = cache
        return WorkflowTestsModel(
            reader: TestHealthReader(cache: cache),
            snapshot: { snapshot },
            loadTests: { run, _ in
                if let failure = loads.failure { return failure }
                loads.runs.append(run.number ?? 0)
                await cache.save(extras(run.number ?? 0), runID: run.id)
                return nil
            },
            budget: { RateLimit(limit: 3_600, remaining: loads.remaining) }
        )
    }

    @Test func showingTheSectionAsksAppleNothing() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        let loads = Loads()
        let model = model(loads)

        await model.refresh(workflowID: "w1")

        #expect(model.report?.analyzedBuilds == 0)
        #expect(model.report?.eligibleBuilds == 3)
        #expect(loads.runs.isEmpty)
        #expect(!model.isAnalyzing)
    }

    @Test func analyzingLoadsTheMissingBuildsOneAfterTheOtherNewestFirst() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        let loads = Loads()
        let model = model(loads)
        await cache.save(extras(4), runID: "run-4")

        await model.analyze(workflowID: "w1")

        #expect(loads.runs == [5, 3])
        #expect(model.report?.analyzedBuilds == 3)
        #expect(!model.isAnalyzing && !model.stoppedForBudget && model.failureMessage == nil)
    }

    @Test func theAnalysisStopsWhenTheHoursRequestsRunShort() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        let loads = Loads()
        loads.remaining = SyncSchedule.criticalRemaining
        let model = model(loads)

        await model.analyze(workflowID: "w1")

        #expect(loads.runs.isEmpty)
        #expect(model.stoppedForBudget)
        #expect(model.report?.analyzedBuilds == 0)
    }

    @Test func aFailureStopsTheAnalysisAndSaysWhy() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        let loads = Loads()
        loads.failure = "App Store Connect returned an error (500)"
        let model = model(loads)

        await model.analyze(workflowID: "w1")

        #expect(model.failureMessage == "App Store Connect returned an error (500)")
        #expect(!model.isAnalyzing)
    }

    @Test func aStoppedAnalysisKeepsWhatItAlreadyRead() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        let loads = Loads()
        let model = model(loads)

        let task = Task { await model.analyze(workflowID: "w1", limit: 1) }
        await task.value
        #expect(loads.runs == [5])

        let cancelled = Task { await model.analyze(workflowID: "w1") }
        cancelled.cancel()
        await cancelled.value
        #expect(loads.runs == [5])
        #expect(model.report?.analyzedBuilds == 1)
    }

    @Test func anotherWorkflowNeverShowsThisOnesFigures() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5), runID: "run-5")
        let model = model(Loads())

        await model.refresh(workflowID: "w1")
        #expect(model.report?.analyzedBuilds == 1)

        await model.refresh(workflowID: "other")
        #expect(model.report?.analyzedBuilds == 0)
        #expect(model.report?.eligibleBuilds == 1)
    }

    @Test func aBuildCanBeOpenedStraightOnItsTestsTab() {
        let navigation = NavigationModel()
        navigation.showBuild("run-1")
        #expect(navigation.buildTab == .actions)

        navigation.showBuild("run-5", tab: .tests)

        #expect(navigation.selectedBuildID == "run-5")
        #expect(navigation.buildTab == .tests)
    }
}
