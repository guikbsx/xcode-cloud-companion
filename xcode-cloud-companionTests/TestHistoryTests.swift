import Foundation
import Testing
@testable import XcodeCloudCompanion

private let day = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private let identity = TestHistory.Identity(actionName: "Test - iOS", className: "CartTests", name: "testCheckout")

private func entry(
    _ number: Int, _ outcome: TestHistory.Outcome, commit: String? = nil, message: String? = nil, file: CIFileLocation? = nil, devices: [TestHistory.DeviceRun] = []
) -> TestHistory.Entry {
    TestHistory.Entry(
        runID: "run-\(number)", number: number, date: day.addingTimeInterval(Double(number) * 3600), commit: commit, outcome: outcome,
        message: message, file: file, devices: devices
    )
}

private func makeHistory(_ entries: [TestHistory.Entry], eligible: Int = 0) -> TestHistory {
    TestHistory(identity: identity, entries: entries, eligibleBuilds: eligible)
}

struct TestHistoryCalculationTests {
    @Test func theBuildsComeOldestFirstAndThirtyAtMost() {
        let shuffled = (1...40).reversed().map { entry($0, .passed) }

        let built = makeHistory(shuffled)

        #expect(built.entries.count == 30)
        #expect(built.entries.first?.number == 11 && built.entries.last?.number == 40)
        #expect(built.entries.map(\.number) == (11...40).map { $0 })
    }

    @Test func theEligibleBuildsAreNeverFewerThanTheOnesRead() {
        #expect(makeHistory([entry(1, .passed), entry(2, .failed)], eligible: 1).eligibleBuilds == 2)
        #expect(makeHistory([entry(1, .passed)], eligible: 41).eligibleBuilds == 41)
    }

    @Test func failuresAndFlakyPassesAreCountedApart() {
        let built = makeHistory([entry(1, .passed), entry(2, .failed), entry(3, .mixed), entry(4, .absent), entry(5, .failed), entry(6, .passed)])

        #expect(built.failedCount == 2 && built.mixedCount == 1)
        #expect(built.analyzedBuilds == 6)
    }

    @Test func theFailingStreakStartsAtItsOldestBuild() throws {
        let built = makeHistory([entry(1, .failed), entry(2, .passed), entry(3, .failed), entry(4, .mixed), entry(5, .failed)])

        let streak = try #require(built.currentStreak)
        #expect(streak.first.number == 3 && streak.builds == 3)
    }

    @Test func thereIsNoStreakWhenTheLatestResultIsAPass() {
        #expect(makeHistory([entry(1, .failed), entry(2, .failed), entry(3, .passed)]).currentStreak == nil)
        #expect(makeHistory([entry(1, .passed)]).currentStreak == nil)
        #expect(makeHistory([]).currentStreak == nil)
    }

    @Test func aBuildWhereTheTestDidNotRunNeitherBreaksNorEndsTheStreak() throws {
        let inside = makeHistory([entry(1, .passed), entry(2, .failed), entry(3, .absent), entry(4, .failed)])
        #expect(inside.currentStreak?.first.number == 2 && inside.currentStreak?.builds == 2)

        let after = makeHistory([entry(1, .passed), entry(2, .failed), entry(3, .absent)])
        #expect(after.currentStreak?.first.number == 2)

        let onlyAbsent = makeHistory([entry(1, .absent), entry(2, .absent)])
        #expect(onlyAbsent.currentStreak == nil)
    }

    @Test func aStreakCanFillTheWholeHistory() throws {
        let built = makeHistory([entry(1, .failed), entry(2, .failed)])

        #expect(built.currentStreak?.first.number == 1 && built.currentStreak?.builds == 2)
    }

    @Test func theLastFailureAndItsMessageAreTheMostRecentOnes() throws {
        let file = CIFileLocation(path: "/Volumes/workspace/repository/Tests/CartTests.swift", lineNumber: 42)
        let built = makeHistory([
            entry(1, .failed, message: "old"), entry(2, .mixed, message: "newer", file: file), entry(3, .failed), entry(4, .passed),
        ])

        #expect(built.lastFailure?.number == 3)
        #expect(built.lastFailureMessage == "newer")
    }

    @Test func withoutAFailureThereIsNothingToOpen() {
        let built = makeHistory([entry(1, .passed), entry(2, .absent)])

        #expect(built.lastFailure == nil && built.lastFailureMessage == nil)
    }

    @Test func theTimePerDeviceIsAveragedOverTheBuildsWhereTheTestRan() {
        let built = makeHistory([
            entry(1, .passed, devices: [.init(name: "iPhone 17", seconds: 1), .init(name: "iPad Air", seconds: 2)]),
            entry(2, .failed, devices: [.init(name: "iPhone 17", seconds: 3), .init(name: "iPad Air", seconds: nil)]),
            entry(3, .absent, devices: [.init(name: "iPhone 17", seconds: 100)]),
        ])

        #expect(built.averageSecondsPerDevice == [.init(name: "iPad Air", seconds: 2), .init(name: "iPhone 17", seconds: 2)])
        #expect(makeHistory([entry(1, .passed)]).averageSecondsPerDevice.isEmpty)
    }

    @Test func aMixedBuildOrAFlipOnTheSameCommitMakesTheTestFlaky() {
        #expect(makeHistory([entry(1, .passed), entry(2, .mixed)]).isFlaky)
        #expect(makeHistory([entry(1, .failed, commit: "aaa"), entry(2, .passed, commit: "aaa")]).isFlaky)
        #expect(!makeHistory([entry(1, .failed, commit: "aaa"), entry(2, .passed, commit: "bbb")]).isFlaky)
        #expect(!makeHistory([entry(1, .failed), entry(2, .passed)]).isFlaky)
        #expect(!makeHistory([entry(1, .failed, commit: "aaa"), entry(2, .absent, commit: "aaa")]).isFlaky)
    }

    @Test func aStatusGivesAnOutcomeAndOnlyFailuresAndMixedAreFailures() {
        #expect(TestHistory.Outcome(.success) == .passed)
        #expect(TestHistory.Outcome(.failure) == .failed)
        #expect(TestHistory.Outcome(.mixed) == .mixed)
        #expect(TestHistory.Outcome(.skipped) == .absent)
        #expect(TestHistory.Outcome(.expectedFailure) == .absent)
        #expect(TestHistory.Outcome(.unknown("X")) == .absent)
        #expect(TestHistory.Outcome(nil) == .absent)
        #expect(TestHistory.Outcome.failed.isFailure && TestHistory.Outcome.mixed.isFailure)
        #expect(!TestHistory.Outcome.passed.isFailure && !TestHistory.Outcome.absent.isFailure)
    }

    @Test func aShortCommitIsSevenCharactersLong() {
        #expect(entry(1, .failed, commit: "a41c7e2b9d0f").shortCommit == "a41c7e2")
        #expect(entry(1, .failed).shortCommit == nil)
    }

    @Test func theIdentityIsTheOneTestHealthUses() {
        let observation = TestHealthReport.Observation(actionName: "Test - iOS", className: "CartTests", name: "testCheckout", status: .success)
        #expect(identity.key == observation.key)
        #expect(TestHistory.Identity(actionName: "Test - iOS", className: "  ", name: "testCheckout").key
            == TestHealthReport.Observation(actionName: "Test - iOS", className: nil, name: "testCheckout", status: .success).key)
        #expect(identity.title == "CartTests · testCheckout")
        #expect(TestHistory.Identity(actionName: "A", className: nil, name: "testX").title == "testX")
    }
}

private func run(_ number: Int, workflow: String = "w1", progress: CIExecutionProgress = .complete, sha: String? = nil) -> CIBuildRun {
    CIBuildRun(
        id: "run-\(number)", productID: "p1", number: number, createdDate: day.addingTimeInterval(Double(number) * 3600), startedDate: nil, finishedDate: nil,
        executionProgress: progress, completionStatus: progress == .complete ? .succeeded : nil, startReason: nil, workflowID: workflow, workflowName: "CI",
        sourceBranchOrTag: nil, sourceCommit: sha.map { CISourceCommit(commitSha: $0, message: nil, authorName: nil, webURL: nil) }
    )
}

private func action(_ number: Int, name: String = "Test - iOS") -> CIBuildAction {
    CIBuildAction(
        id: "action-\(number)", buildRunID: "run-\(number)", name: name, actionType: .test, startedDate: nil, finishedDate: nil,
        executionProgress: .complete, completionStatus: nil, isRequiredToPass: true
    )
}

private func result(
    _ number: Int, _ name: String = "testCheckout", class className: String? = "CartTests", status: CITestStatus, message: String? = nil, file: CIFileLocation? = nil
) -> CITestResult {
    CITestResult(
        id: "t\(number)-\(name)", buildActionID: "action-\(number)", className: className, name: name, status: status, message: message, file: file,
        devices: [
            CITestDeviceResult(deviceName: "iPhone 17 Pro", osVersion: "27.0", status: status, duration: 12),
            CITestDeviceResult(deviceName: "iPad Pro 13", osVersion: "27.0", status: .success, duration: 8),
        ]
    )
}

private func extras(_ number: Int, _ results: [CITestResult], complete: Bool = true) -> BuildExtras {
    BuildExtras(testsByAction: ["action-\(number)": results], testsComplete: complete)
}

struct TestHistoryEntryTests {
    @Test func aBuildWhoseTestsAreNotAllLoadedGivesNothing() {
        let found = [result(5, status: .failure)]

        #expect(TestHistory.entry(of: run(5), actions: [action(5)], extras: nil, identity: identity) == nil)
        #expect(TestHistory.entry(of: run(5), actions: [action(5)], extras: extras(5, found, complete: false), identity: identity) == nil)
    }

    @Test func aFailureKeepsItsMessageItsFileAndItsDevices() throws {
        let file = CIFileLocation(path: "/Volumes/workspace/repository/Tests/CartTests.swift", lineNumber: 42)
        let found = [result(5, status: .failure, message: "  XCTAssertEqual failed  ", file: file)]

        let entry = try #require(TestHistory.entry(of: run(5, sha: "a41c7e2b9d"), actions: [action(5)], extras: extras(5, found), identity: identity))

        #expect(entry.outcome == .failed && entry.number == 5 && entry.commit == "a41c7e2b9d" && entry.runID == "run-5")
        #expect(entry.message == "  XCTAssertEqual failed  ".nilIfBlank)
        #expect(entry.file == file)
        #expect(entry.devices == [.init(name: "iPhone 17 Pro", seconds: 12), .init(name: "iPad Pro 13", seconds: 8)])
    }

    @Test func aPassKeepsNoMessageAndNoFile() throws {
        let file = CIFileLocation(path: "/Volumes/workspace/repository/Tests/CartTests.swift", lineNumber: 42)
        let found = [result(5, status: .success, message: "ignored", file: file)]

        let entry = try #require(TestHistory.entry(of: run(5), actions: [action(5)], extras: extras(5, found), identity: identity))

        #expect(entry.outcome == .passed && entry.message == nil && entry.file == nil)
    }

    @Test func aBuildWithoutTheTestIsAbsentAndItsOtherTestsAreIgnored() throws {
        let found = [
            result(5, "testOther", status: .failure), result(5, class: "OtherTests", status: .failure),
        ]
        let entry = try #require(TestHistory.entry(of: run(5), actions: [action(5)], extras: extras(5, found), identity: identity))

        #expect(entry.outcome == .absent && entry.message == nil && entry.devices.isEmpty)
        #expect(entry.number == 5)
    }

    @Test func theSameNameInAnotherActionIsAnotherTest() throws {
        let macAction = CIBuildAction(
            id: "action-mac", buildRunID: "run-5", name: "Test - macOS", actionType: .test, startedDate: nil, finishedDate: nil,
            executionProgress: .complete, completionStatus: nil, isRequiredToPass: true
        )
        let results = BuildExtras(testsByAction: ["action-5": [result(5, status: .success)], "action-mac": [result(5, status: .failure)]], testsComplete: true)

        let entry = try #require(TestHistory.entry(of: run(5), actions: [action(5), macAction], extras: results, identity: identity))

        #expect(entry.outcome == .passed)
    }

    @Test func aSkippedTestGivesNoVerdict() throws {
        let entry = try #require(TestHistory.entry(of: run(5), actions: [action(5)], extras: extras(5, [result(5, status: .skipped)]), identity: identity))

        #expect(entry.outcome == .absent && entry.devices.isEmpty)
    }

    @Test func theResultsOfABuildAreIdentifiedByTheirAction() {
        let results = ["action-5": [result(5, status: .success)], "action-6": [result(6, "testOther", class: nil, status: .success)]]

        let identities = TestHistory.Identity.identities(of: results, actions: [action(5), action(6, name: "Test - macOS")])

        #expect(identities["t5-testCheckout"] == identity)
        #expect(identities["t6-testOther"] == TestHistory.Identity(actionName: "Test - macOS", className: nil, name: "testOther"))
    }
}

private let snapshot = BuildSnapshot(
    runs: [run(5, sha: "aaa"), run(4, sha: "aaa"), run(3), run(2, progress: .running), run(1, workflow: "other"), run(6)],
    actionsByRunID: ["run-5": [action(5)], "run-4": [action(4)], "run-3": [action(3)], "run-2": [action(2)], "run-1": [action(1)]]
)

struct TestHistoryReaderTests {
    private let cache = BuildExtrasCache(directory: FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)"))

    @Test func theHistoryIsReadFromWhatIsOnDiskAndSaysHowMuchThatIs() async throws {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5, [result(5, status: .failure, message: "boom")]), runID: "run-5")
        await cache.save(extras(4, [result(4, status: .success)]), runID: "run-4")
        await cache.save(extras(1, [result(1, status: .failure)]), runID: "run-1")

        let history = await TestHealthReader(cache: cache).history(of: identity, workflowID: "w1", in: snapshot)

        #expect(history.entries.map(\.number) == [4, 5])
        #expect(history.entries.map(\.outcome) == [.passed, .failed])
        #expect(history.analyzedBuilds == 2 && history.eligibleBuilds == 3)
        #expect(history.lastFailureMessage == "boom")
        #expect(history.isFlaky)
    }

    @Test func aBuildWhereTheTestIsAbsentIsAnEntryAndABuildNotLoadedIsNot() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5, [result(5, "testOther", status: .success)]), runID: "run-5")
        await cache.save(extras(4, [result(4, status: .success)], complete: false), runID: "run-4")

        let history = await TestHealthReader(cache: cache).history(of: identity, workflowID: "w1", in: snapshot)

        #expect(history.entries.map(\.outcome) == [.absent])
        #expect(history.analyzedBuilds == 1 && history.eligibleBuilds == 3)
    }

    @Test func onlyTheThirtyNewestBuildsAreRead() async {
        let runs = (1...45).map { run($0) }
        let big = BuildSnapshot(runs: runs, actionsByRunID: Dictionary(uniqueKeysWithValues: (1...45).map { ("run-\($0)", [action($0)]) }))
        let directory = FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)")
        let cache = BuildExtrasCache(directory: directory)
        defer { Task { await cache.deleteAll() } }
        for number in 1...45 {
            await cache.save(extras(number, [result(number, status: number == 20 ? .failure : .success)]), runID: "run-\(number)")
        }

        let history = await TestHealthReader(cache: cache).history(of: identity, workflowID: "w1", in: big)

        #expect(history.entries.count == 30)
        #expect(history.entries.first?.number == 16 && history.entries.last?.number == 45)
        #expect(history.eligibleBuilds == 45)
        #expect(history.failedCount == 1)
    }

    @Test func nothingOnDiskGivesAnEmptyHistory() async {
        let history = await TestHealthReader(cache: cache).history(of: identity, workflowID: "w1", in: snapshot)

        #expect(history.entries.isEmpty && history.eligibleBuilds == 3)
        #expect(history.currentStreak == nil && history.lastFailure == nil)
    }
}

@MainActor
struct TestHistoryModelTests {
    private let cache = BuildExtrasCache(directory: FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)"))

    private final class Loads {
        var count = 0
    }

    private func model(_ loads: Loads, allowed: @escaping @MainActor () -> Bool) -> WorkflowTestsModel {
        WorkflowTestsModel(
            reader: TestHealthReader(cache: cache),
            snapshot: { snapshot },
            loadTests: { _, _ in
                loads.count += 1
                return nil
            },
            budget: { loads.count += 1000; return RateLimit(limit: 3_600, remaining: 3_000) },
            allowed: allowed
        )
    }

    @Test func readingAHistoryAsksAppleNothing() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5, [result(5, status: .failure)]), runID: "run-5")
        let loads = Loads()

        let history = await model(loads, allowed: { true }).history(of: identity, workflowID: "w1")

        #expect(history?.entries.map(\.outcome) == [.failed])
        #expect(loads.count == 0)
    }

    @Test func withoutProNothingIsReadFromTheDisk() async {
        defer { Task { [cache] in await cache.deleteAll() } }
        await cache.save(extras(5, [result(5, status: .failure)]), runID: "run-5")
        let loads = Loads()

        let history = await model(loads, allowed: { false }).history(of: identity, workflowID: "w1")

        #expect(history == nil)
        #expect(loads.count == 0)
    }
}

struct TestHistoryReportStripTests {
    private func sample(_ number: Int, _ tests: [TestHealthReport.Observation]) -> TestHealthReport.Sample {
        TestHealthReport.Sample(runID: "run-\(number)", number: number, date: day.addingTimeInterval(Double(number) * 3600), commit: "c\(number / 2)", tests: tests)
    }

    private func observation(_ status: CITestStatus) -> TestHealthReport.Observation {
        TestHealthReport.Observation(actionName: "Test - iOS", className: "CartTests", name: "testCheckout", status: status)
    }

    @Test func aFlakyTestCarriesItsResultInEachOfTheLastBuildsOldestFirst() throws {
        let report = TestHealthReport(samples: [
            sample(4, [observation(.success)]),
            sample(1, [observation(.failure)]),
            sample(3, []),
            sample(2, [observation(.mixed)]),
            sample(5, [observation(.skipped)]),
        ], eligibleBuilds: 5)

        let flaky = try #require(report.flaky.first)
        #expect(flaky.recent == [.failed, .mixed, .absent, .passed, .absent])
    }

    @Test func theStripCoversThirtyBuildsAtMost() throws {
        let samples = (1...40).map { sample($0, [observation($0 == 3 ? .mixed : .success)]) } + [sample(41, [observation(.mixed)])]

        let report = TestHealthReport(samples: samples, eligibleBuilds: 41)

        let flaky = try #require(report.flaky.first)
        #expect(flaky.recent.count == 30)
        #expect(flaky.recent.last == .mixed)
    }

    @Test func theRowsOfTheTestsTabKnowTheirTest() throws {
        let results = ["action-5": [result(5, status: .failure), result(5, "testOther", class: nil, status: .success)]]

        let model = TestsTabModel(results: results, actions: [action(5)])

        let rows = model.groups.flatMap(\.rows)
        #expect(rows.compactMap(\.identity).contains(identity))
        #expect(rows.compactMap(\.identity).contains(TestHistory.Identity(actionName: "Test - iOS", className: nil, name: "testOther")))
    }
}

struct TestHistoryTextTests {
    @Test func theSquaresAreLabelledByStateAndBuild() {
        #expect(TestHistoryText.label(of: entry(398, .failed)) == "Failed, build 398")
        #expect(TestHistoryText.label(of: entry(398, .passed)) == "Passed, build 398")
        #expect(TestHistoryText.label(of: entry(398, .mixed)) == "Flaky, build 398")
        #expect(TestHistoryText.label(of: entry(398, .absent)) == "Not run, build 398")
        #expect(TestHistoryText.label(of: TestHistory.Entry(runID: "r", number: nil, date: nil, commit: nil, outcome: .failed)) == "Failed")
    }

    @Test func theSummaryNamesFailuresFlakyPassesAndBuilds() {
        let entries = (1...30).map { entry($0, [3, 9, 20, 25].contains($0) ? .failed : [11, 14].contains($0) ? .mixed : .passed) }

        #expect(TestHistoryText.summary(of: makeHistory(entries)) == "4 failures and 2 flaky passes in 30 builds")
        #expect(TestHistoryText.results(failed: 1, mixed: 0) == "1 failure")
        #expect(TestHistoryText.results(failed: 0, mixed: 1) == "1 flaky pass")
        #expect(TestHistoryText.results(failed: 0, mixed: 0) == "No failure")
        #expect(TestHistoryText.results(failed: 4, mixed: 2) == "4 failures and 2 flaky passes")
    }

    @Test func theSkeletonLastsWhileTheDiskIsBeingRead() {
        #expect(SkeletonRules.testHistory(hasRead: false))
        #expect(!SkeletonRules.testHistory(hasRead: true))
    }

    @Test func theTestHealthBenefitStillSpeaksForTheHistory() {
        #expect(ProBenefit.diagnostics.features.contains(.testHealth))
        #expect(ProFeatureText.sentence(.testHealth).contains("thirty"))
    }
}
