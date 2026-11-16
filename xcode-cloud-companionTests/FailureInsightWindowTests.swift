import Foundation
import FoundationModels
import Testing
@testable import XcodeCloudCompanion

private let day = Date(timeIntervalSince1970: 1_791_547_200)
private let repo = "/Volumes/workspace/repository/"

private func run(_ id: String = "run-412", status: CICompletionStatus? = .failed, progress: CIExecutionProgress = .complete) -> CIBuildRun {
    CIBuildRun(
        id: id, productID: "p1", number: 412, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(372),
        executionProgress: progress, completionStatus: status, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Release",
        sourceBranchOrTag: "main"
    )
}

private func action(_ id: String, type: CIActionType, runID: String = "run-412") -> CIBuildAction {
    CIBuildAction(
        id: id, buildRunID: runID, name: id, actionType: type, startedDate: day, finishedDate: day, executionProgress: .complete,
        completionStatus: .failed, isRequiredToPass: true, issueCounts: nil
    )
}

private func failing(_ name: String, class className: String = "CartTests", action: String = "test", status: CITestStatus = .failure) -> CITestResult {
    CITestResult(
        id: "\(action)-\(className)-\(name)", buildActionID: action, className: className, name: name, status: status, message: "XCTAssertEqual failed",
        file: CIFileLocation(path: repo + "Tests/CartTests.swift", lineNumber: 12),
        devices: [CITestDeviceResult(deviceName: "iPhone 17", osVersion: "26.0", status: .failure, duration: 1)]
    )
}

private func tests(_ count: Int) -> [CITestResult] {
    (0..<count).map { failing(String(format: "testCase%02d", $0)) }
}

private let snapshot = BuildSnapshot(
    products: [CIProduct(id: "p1", name: "cart", productType: "APP", appID: "1", appName: "Cart", bundleID: nil)], runs: [run()],
    actionsByRunID: ["run-412": [action("build", type: .build), action("test", type: .test)]]
)

private actor FakeGenerator: FailureInsightGenerating {
    private var answer: RawFailureInsight?
    private(set) var requests = 0
    private(set) var languages: [FailureInsightLanguage] = []

    init(_ answer: RawFailureInsight?) {
        self.answer = answer
    }

    func generate(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) async throws -> RawFailureInsight {
        requests += 1
        languages.append(language)
        guard let answer else { throw FailureInsightError.unavailable("scripted") }
        return answer
    }
}

private let twoGroups = [
    FailureInsight.Group(title: "Totaux", testIndexes: [0, 1, 2]), FailureInsight.Group(title: "Arrondis", testIndexes: [3, 4]),
]

@MainActor
private struct Rig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "insight-\(UUID().uuidString)")
    var insights: URL { directory.appending(path: "insights") }

    func extrasCache(issues: [CIIssue] = [], failed: [CITestResult]) async -> BuildExtrasCache {
        let cache = BuildExtrasCache(directory: directory.appending(path: "details"))
        await cache.save(
            BuildExtras(
                issuesByAction: Dictionary(grouping: issues, by: \.buildActionID), testsByAction: ["test": failed],
                issuesComplete: true, testsComplete: true
            ),
            runID: "run-412"
        )
        return cache
    }

    func store(
        failed: [CITestResult], generator: any FailureInsightGenerating, language: FailureInsightLanguage = .english, open: Bool = true
    ) async throws -> FailureInsightStore {
        let cache = BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json"))
        try await cache.save(snapshot)
        let buildStore = BuildStore(cacheStore: cache)
        await buildStore.loadCacheIfNeeded()
        let extras = BuildExtrasStore(cache: await extrasCache(failed: failed), client: { nil })
        let store = FailureInsightStore(
            buildStore: buildStore, extrasStore: extras, cache: FailureInsightCache(directory: insights), service: FailureInsightService(generator: generator),
            language: { language }
        )
        store.isOpen = { open }
        return store
    }
}

@MainActor
struct FailureInsightStoreTests {
    private let rig = Rig()

    @Test func anInsightIsMadeOnceKeptOnDiskAndNeverAskedAgain() async throws {
        let generator = FakeGenerator(RawFailureInsight(headline: "8 tests de CartTests échouent", groups: twoGroups))
        let store = try await rig.store(failed: tests(8), generator: generator)

        await store.load(run())
        let record = try #require(store.insight(for: "run-412"))

        #expect(record.category == .tests)
        #expect(record.headline == "8 tests de CartTests échouent")
        #expect(record.groups?.map(\.title) == ["Totaux", "Arrondis"])
        #expect(await generator.requests == 1)

        let restarted = FakeGenerator(nil)
        let again = try await rig.store(failed: tests(8), generator: restarted)
        await again.load(run())

        #expect(again.insight(for: "run-412") == record)
        #expect(await restarted.requests == 0)
    }

    @Test func groupsAreKeptAsTestIdentitiesNotPositions() async throws {
        let store = try await rig.store(failed: tests(8), generator: FakeGenerator(RawFailureInsight(headline: "8 tests de CartTests échouent", groups: twoGroups)))

        await store.load(run())

        let first = try #require(store.insight(for: "run-412")?.groups?.first)
        #expect(first.tests == [
            .init(action: "test", className: "CartTests", name: "testCase00"), .init(action: "test", className: "CartTests", name: "testCase01"),
            .init(action: "test", className: "CartTests", name: "testCase02"),
        ])
    }

    @Test func aModelThatGivesNothingIsCachedAsTheCategoryAlone() async throws {
        let generator = FakeGenerator(nil)
        let store = try await rig.store(failed: tests(2), generator: generator)

        await store.load(run())

        #expect(store.insight(for: "run-412") == FailureInsightRecord(category: .tests))
        #expect(await generator.requests == 1)

        let later = FakeGenerator(RawFailureInsight(headline: "2 tests de CartTests échouent", groups: []))
        let again = try await rig.store(failed: tests(2), generator: later)
        await again.load(run())

        #expect(again.insight(for: "run-412")?.headline == nil)
        #expect(await later.requests == 0)
    }

    @Test func eachLanguageHasItsOwnCacheAndItsOwnRequest() async throws {
        let english = FakeGenerator(RawFailureInsight(headline: "2 tests of CartTests fail", groups: []))
        try await rig.store(failed: tests(2), generator: english, language: .english).load(run())
        let french = FakeGenerator(RawFailureInsight(headline: "2 tests de CartTests échouent", groups: []))
        let store = try await rig.store(failed: tests(2), generator: french, language: .french)

        await store.load(run())

        #expect(store.insight(for: "run-412")?.headline == "2 tests de CartTests échouent")
        #expect(await french.requests == 1)
        #expect(await french.languages == [.french])
    }

    @Test func nothingIsReadOrGeneratedWhenTheFeatureIsNotOpen() async throws {
        let generator = FakeGenerator(RawFailureInsight(headline: "2 tests de CartTests échouent", groups: []))
        let store = try await rig.store(failed: tests(2), generator: generator, open: false)

        await store.load(run())

        #expect(store.insight(for: "run-412") == nil)
        #expect(await generator.requests == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.insights.path))
    }

    @Test func onlyAFinishedFailedBuildHasAnInsight() async throws {
        let generator = FakeGenerator(RawFailureInsight(headline: "x", groups: []))
        let store = try await rig.store(failed: tests(2), generator: generator)

        await store.load(run(status: .succeeded))
        await store.load(run(status: .failed, progress: .running))

        #expect(store.insight(for: "run-412") == nil)
        #expect(await generator.requests == 0)
    }

    @Test func aBuildWhoseDataCannotBeReadHasNoCardAndNothingIsKept() async throws {
        let generator = FakeGenerator(RawFailureInsight(headline: "x", groups: []))
        let cache = BuildCacheStore(fileURL: rig.directory.appending(path: "BuildCache.json"))
        try await cache.save(snapshot)
        let buildStore = BuildStore(cacheStore: cache)
        await buildStore.loadCacheIfNeeded()
        let store = FailureInsightStore(
            buildStore: buildStore, extrasStore: BuildExtrasStore(cache: BuildExtrasCache(directory: rig.directory.appending(path: "empty")), client: { nil }),
            cache: FailureInsightCache(directory: rig.insights), service: FailureInsightService(generator: generator), language: { .english }
        )

        await store.load(run())

        #expect(store.insight(for: "run-412") == nil)
        #expect(await generator.requests == 0)
        #expect(!store.isLoading("run-412"))
    }

    @Test func resettingForgetsMemoryAndDisk() async throws {
        let store = try await rig.store(failed: tests(2), generator: FakeGenerator(nil))
        await store.load(run())

        await store.reset()

        #expect(store.insight(for: "run-412") == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.insights.path))
    }
}

@MainActor
struct FailureInsightAccessTests {
    private let accounts = TestAccounts()

    private func session(_ status: FailureInsightFeature.ModelStatus) -> AccountSession {
        let paths = accounts.paths("work")
        let store = InMemoryCredentialsStore()
        let buildStore = BuildStore(credentialsStore: store, cacheStore: BuildCacheStore(fileURL: paths.buildCache))
        return AccountSession(
            account: Account(id: "work", name: "Work"), paths: paths,
            settings: SettingsModel(accountID: "work", store: store, defaults: accounts.defaults),
            buildStore: buildStore, usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(cache: BuildExtrasCache(directory: paths.buildDetails), client: { nil }),
            defaults: accounts.defaults, modelStatus: { status }
        )
    }

    @Test func theDecisionTable() {
        for model in [FailureInsightFeature.ModelStatus.available, .deviceNotEligible, .notEnabled, .notReady] {
            for setting in [true, false] {
                let expected: FailureInsightFeature.Mode = model != .available || !setting ? .hidden : .open
                #expect(FailureInsightFeature.mode(model: model, settingOn: setting) == expected)
            }
        }
    }

    @Test func theSettingIsOnUntilTheUserTurnsItOff() {
        let defaults = accounts.defaults

        #expect(FailureInsightFeature.isSettingOn(defaults))
        defaults.set(false, forKey: FailureInsightFeature.settingKey)
        #expect(!FailureInsightFeature.isSettingOn(defaults))
    }

    @Test func eachReasonTheModelIsMissingHasItsWords() {
        #expect(FailureInsightFeature.ModelStatus.available.reason == nil)
        let reasons = [FailureInsightFeature.ModelStatus.deviceNotEligible, .notEnabled, .notReady].map(\.reason)
        #expect(reasons.allSatisfy { $0?.isEmpty == false })
        #expect(Set(reasons).count == 3)
    }

    @Test func theModelsAvailabilityIsTranslated() {
        #expect(FailureInsightFeature.ModelStatus(.available) == .available)
        #expect(FailureInsightFeature.ModelStatus(.unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(FailureInsightFeature.ModelStatus(.unavailable(.appleIntelligenceNotEnabled)) == .notEnabled)
        #expect(FailureInsightFeature.ModelStatus(.unavailable(.modelNotReady)) == .notReady)
    }

    @Test func anAccountOpensTheFeatureOnlyWithTheModelAndTheSetting() {
        let session = session(.available)
        let store = session.failureInsights

        #expect(store.isOpen())
        accounts.defaults.set(false, forKey: FailureInsightFeature.settingKey)
        #expect(!store.isOpen())
        #expect(!self.session(.notEnabled).failureInsights.isOpen())
    }

    @Test func erasingAnAccountErasesItsInsights() async throws {
        let work = try await accounts.add("Work")
        let paths = accounts.paths(work.id)
        await FailureInsightCache(directory: paths.failureInsights).save(FailureInsightRecord(category: .tests), runID: "run-412", language: .english)
        #expect(FileManager.default.fileExists(atPath: paths.failureInsights.path))

        #expect(await accounts.model.remove(work.id))

        #expect(!FileManager.default.fileExists(atPath: paths.failureInsights.path))
    }
}

struct FailureInsightRecordTests {
    @Test func positionsBecomeIdentitiesAgainstTheListThatWasSent() {
        let failed = tests(6)
        let insight = FailureInsight(
            category: .tests, headline: "6 tests de CartTests échouent",
            groups: [.init(title: "A", testIndexes: [0, 5]), .init(title: "B", testIndexes: [2, 99, -1, 3])]
        )

        let record = FailureInsightRecord(category: .tests, insight: insight, failedTests: failed)

        #expect(record.groups?.first?.tests.map(\.name) == ["testCase00", "testCase05"])
        #expect(record.groups?.last?.tests.map(\.name) == ["testCase02", "testCase03"])
    }

    @Test func fewerThanTwoGroupsLeftMeansNoGroups() {
        let insight = FailureInsight(category: .tests, headline: "h", groups: [.init(title: "A", testIndexes: [1]), .init(title: "B", testIndexes: [50])])

        #expect(FailureInsightRecord(category: .tests, insight: insight, failedTests: tests(6)).groups == nil)
        #expect(FailureInsightRecord(category: .tests, insight: nil, failedTests: tests(6)) == FailureInsightRecord(category: .tests))
    }

    @Test func aRecordSurvivesTheDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "record-\(UUID().uuidString)")
        let cache = FailureInsightCache(directory: directory)
        let record = FailureInsightRecord(
            category: .distribution, headline: "L'export de l'archive a échoué",
            groups: [.init(title: "A", tests: [.init(action: "t", className: "C", name: "n")])]
        )

        await cache.save(record, runID: "run-1", language: .french)

        #expect(await cache.load(runID: "run-1", language: .french) == record)
        #expect(await cache.load(runID: "run-1", language: .english) == nil)
        #expect(await cache.load(runID: "../escape", language: .french) == nil)
    }

    @Test func theLanguageIsFrenchOnlyWhenTheAppAndTheModelBothAre() {
        #expect(FailureInsightLanguage(appLanguage: "fr", modelWritesFrench: true) == .french)
        #expect(FailureInsightLanguage(appLanguage: "fr", modelWritesFrench: false) == .english)
        #expect(FailureInsightLanguage(appLanguage: "en", modelWritesFrench: true) == .english)
        #expect(FailureInsightLanguage(appLanguage: nil, modelWritesFrench: true) == .english)
    }

    @Test func allEightCategoriesHaveAName() {
        let names = FailureCategory.allCases.map(\.displayName)

        #expect(names == ["Compilation", "Tests", "Flaky Test", "Signing", "Configuration", "Distribution", "Infrastructure", "Other"])
    }
}

struct SuggestedTestSectionsTests {
    private func record(_ groups: [(String, [Int])], in failed: [CITestResult]) -> FailureInsightRecord {
        FailureInsightRecord(
            category: .tests, headline: nil,
            groups: groups.map { title, indexes in .init(title: title, tests: indexes.map { FailureInsightRecord.TestIdentity(failed[$0]) }) }
        )
    }

    @Test func groupsComeFirstAndTheRestGoInOthers() throws {
        let failed = tests(10)
        let sections = try #require(SuggestedTestSections(record: record([("Totaux", [0, 1, 2, 3, 4]), ("Arrondis", [7, 8])], in: failed), failed: failed))

        #expect(sections.sections.map(\.title) == ["Totaux", "Arrondis", nil])
        #expect(sections.sections.map(\.count) == [5, 2, 3])
        #expect(sections.sections.last?.isOthers == true)
        #expect(sections.sections.last?.rows.map(\.name) == ["testCase05", "testCase06", "testCase09"])
    }

    @Test func aTestAppearsOnce() throws {
        let failed = tests(8)
        let sections = try #require(SuggestedTestSections(record: record([("A", [0, 1, 2]), ("B", [2, 3, 4])], in: failed), failed: failed))

        let names = sections.sections.flatMap { $0.rows.map(\.name) }
        #expect(names.count == 8)
        #expect(Set(names).count == 8)
        #expect(sections.sections.map(\.count) == [3, 2, 3])
    }

    @Test func nothingIsOthersWhenEveryTestIsInAGroup() throws {
        let failed = tests(6)
        let sections = try #require(SuggestedTestSections(record: record([("A", [0, 1, 2]), ("B", [3, 4, 5])], in: failed), failed: failed))

        #expect(sections.sections.map(\.isOthers) == [false, false])
    }

    @Test func onlyThreeTestsShowUntilAskedForTheRest() throws {
        let failed = tests(12)
        let sections = try #require(SuggestedTestSections(record: record([("A", Array(0..<9)), ("B", [9, 10])], in: failed), failed: failed))
        let big = sections.sections[0]

        #expect(big.visibleRows(showingAll: false).count == 3)
        #expect(big.hiddenCount == 6)
        #expect(big.visibleRows(showingAll: true).count == 9)
        #expect(sections.sections[1].hiddenCount == 0)
    }

    @Test func noSectionsWithoutGroupsOrWithFewFailedTests() {
        let failed = tests(8)

        #expect(SuggestedTestSections(record: nil, failed: failed) == nil)
        #expect(SuggestedTestSections(record: FailureInsightRecord(category: .tests), failed: failed) == nil)
        let few = Array(failed.prefix(5))
        #expect(SuggestedTestSections(record: record([("A", [0, 1]), ("B", [2, 3])], in: failed), failed: few) == nil)
    }

    @Test func groupsWhoseTestsAreGoneFromTheBuildAreNotShown() {
        let failed = tests(8)
        let other = (0..<8).map { failing("other\($0)", class: "OtherTests") }

        #expect(SuggestedTestSections(record: record([("A", [0, 1]), ("B", [2, 3])], in: failed), failed: other) == nil)
    }
}
