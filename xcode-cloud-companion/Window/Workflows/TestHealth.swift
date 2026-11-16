import Foundation
import Observation

/// Which tests of a workflow are flaky and which are slow, over the builds whose test results the app already holds.
/// Always a sample: it says how many builds it read.
nonisolated struct TestHealthReport: Equatable, Sendable {
    /// One test in one build, reduced to what the report needs.
    struct Observation: Equatable, Sendable {
        var actionName: String
        var className: String?
        var name: String
        var status: CITestStatus
        /// Devices on which it failed in this build.
        var failedDevices: [String] = []
        /// How long it ran on each device.
        var deviceSeconds: [Double] = []

        var key: String { [actionName, className ?? "", name].joined(separator: "\u{1F}") }
    }

    /// One analyzed build.
    struct Sample: Equatable, Sendable {
        var runID: String
        var number: Int?
        var date: Date?
        var commit: String?
        var tests: [Observation]
    }

    struct FlakyTest: Identifiable, Equatable, Sendable {
        let id: String
        let className: String?
        let name: String
        let actionName: String
        let failures: Int
        let runs: Int
        let lastFailureRunID: String
        let lastFailureNumber: Int?
        let lastFailureDate: Date?
        let devices: [String]
        /// Its results differed between devices within one build.
        let differsBetweenDevices: Bool
        /// It both failed and passed on one and the same commit.
        let flipsOnSameCommit: Bool
        /// Its result in each of the last builds analyzed, oldest first: the strip of its row.
        var recent: [TestHistory.Outcome] = []
    }

    struct SlowTest: Identifiable, Equatable, Sendable {
        let id: String
        let className: String?
        let name: String
        let actionName: String
        let averageSecondsPerDevice: Double
        /// Its share of all the test time measured, 0...1.
        let share: Double
    }

    static let slowestCount = 10

    /// The Tests section's skeleton: a sample of the size a workflow usually has, never shown as figures.
    static let placeholder: TestHealthReport = {
        var report = TestHealthReport(samples: [], eligibleBuilds: 12)
        report.analyzedBuilds = 8
        report.flaky = [FlakyTest(
            id: "placeholder-flaky", className: "SettingsTests", name: "testSavingASettingKeepsItsValue()", actionName: "Test", failures: 2, runs: 8,
            lastFailureRunID: "placeholder", lastFailureNumber: 41, lastFailureDate: nil, devices: ["iPhone 17"], differsBetweenDevices: false, flipsOnSameCommit: true,
            recent: [.passed, .passed, .failed, .passed, .mixed, .passed, .passed, .failed]
        )]
        report.slowest = [
            SlowTest(id: "placeholder-slow-0", className: "SyncTests", name: "testAFullSyncReadsEveryProduct()", actionName: "Test", averageSecondsPerDevice: 42, share: 0.18),
            SlowTest(id: "placeholder-slow-1", className: "UsageTests", name: "testTheCycleIsMeasuredBuildByBuild()", actionName: "Test", averageSecondsPerDevice: 31, share: 0.12),
        ]
        return report
    }()

    var analyzedBuilds = 0
    /// Finished builds of the workflow that ran tests: what a full analysis would cover.
    var eligibleBuilds = 0
    var flaky: [FlakyTest] = []
    var slowest: [SlowTest] = []

    init(samples: [Sample], eligibleBuilds: Int) {
        analyzedBuilds = samples.count
        self.eligibleBuilds = max(eligibleBuilds, samples.count)

        struct Occurrence {
            var sample: Sample
            var test: Observation
        }
        var occurrences: [String: [Occurrence]] = [:]
        for sample in samples {
            for test in sample.tests where test.status == .success || test.status.isFailure {
                occurrences[test.key, default: []].append(Occurrence(sample: sample, test: test))
            }
        }

        var totalSeconds = 0.0
        var slow: [SlowTest] = []
        for (key, runs) in occurrences {
            guard let first = runs.first?.test else { continue }
            let failures = runs.filter { $0.test.status.isFailure }
            let differs = runs.contains { $0.test.status == .mixed }
            // Failing on one commit and passing on the next may be a fix; only a flip on the very same commit is flakiness.
            let byCommit = Dictionary(grouping: runs.filter { $0.sample.commit != nil }, by: { $0.sample.commit ?? "" })
            let flips = byCommit.values.contains { group in
                group.contains { $0.test.status.isFailure } && group.contains { $0.test.status == .success }
            }
            if differs || flips, let last = failures.max(by: { Self.isEarlier($0.sample, $1.sample) }) {
                flaky.append(FlakyTest(
                    id: key, className: first.className, name: first.name, actionName: first.actionName, failures: failures.count, runs: runs.count,
                    lastFailureRunID: last.sample.runID, lastFailureNumber: last.sample.number, lastFailureDate: last.sample.date,
                    devices: Set(failures.flatMap(\.test.failedDevices)).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                    differsBetweenDevices: differs, flipsOnSameCommit: flips
                ))
            }

            let seconds = runs.flatMap(\.test.deviceSeconds)
            let sum = seconds.reduce(0, +)
            totalSeconds += sum
            if !seconds.isEmpty, sum > 0 {
                slow.append(SlowTest(
                    id: key, className: first.className, name: first.name, actionName: first.actionName,
                    averageSecondsPerDevice: sum / Double(seconds.count), share: sum
                ))
            }
        }
        flaky.sort { ($0.failures, $1.id) > ($1.failures, $0.id) }
        let window = samples.sorted { Self.isEarlier($0, $1) }.suffix(TestHistory.maxBuilds)
        flaky = flaky.map { test in
            var test = test
            let statuses = Dictionary(occurrences[test.id, default: []].map { ($0.sample.runID, $0.test.status) }, uniquingKeysWith: { first, _ in first })
            test.recent = window.map { TestHistory.Outcome(statuses[$0.runID]) }
            return test
        }
        slowest = slow
            .sorted { ($0.averageSecondsPerDevice, $1.id) > ($1.averageSecondsPerDevice, $0.id) }
            .prefix(Self.slowestCount)
            .map { test in
                SlowTest(
                    id: test.id, className: test.className, name: test.name, actionName: test.actionName,
                    averageSecondsPerDevice: test.averageSecondsPerDevice, share: totalSeconds > 0 ? test.share / totalSeconds : 0
                )
            }
    }

    /// Finished builds of the workflow with a finished test action, newest first.
    static func eligibleRuns(workflowID: String, in snapshot: BuildSnapshot) -> [CIBuildRun] {
        snapshot.runs
            .filter { run in
                run.workflowID == workflowID && run.executionProgress == .complete
                    && (snapshot.actionsByRunID[run.id] ?? []).contains { $0.actionType == .test && $0.executionProgress == .complete }
            }
            .sorted { isEarlier($1, $0) }
    }

    /// What one build's cached details hold, or nil while its tests are not all there.
    static func sample(of run: CIBuildRun, actions: [CIBuildAction], extras: BuildExtras?) -> Sample? {
        guard let extras, extras.testsComplete else { return nil }
        var tests: [Observation] = []
        for action in actions {
            for test in extras.testsByAction[action.id] ?? [] {
                tests.append(Observation(
                    actionName: action.name ?? "", className: test.className?.nilIfBlank, name: test.name ?? test.id, status: test.status,
                    failedDevices: test.devices.filter { $0.status.isFailure }.map(\.deviceName),
                    deviceSeconds: test.devices.compactMap(\.duration)
                ))
            }
        }
        return Sample(runID: run.id, number: run.number, date: run.createdDate, commit: run.sourceCommit?.commitSha?.nilIfBlank, tests: tests)
    }

    private static func isEarlier(_ lhs: Sample, _ rhs: Sample) -> Bool {
        (lhs.number ?? 0, lhs.date ?? .distantPast) < (rhs.number ?? 0, rhs.date ?? .distantPast)
    }

    private static func isEarlier(_ lhs: CIBuildRun, _ rhs: CIBuildRun) -> Bool {
        (lhs.number ?? 0, lhs.createdDate ?? .distantPast) < (rhs.number ?? 0, rhs.createdDate ?? .distantPast)
    }
}

/// Reads the cached test results of a workflow's builds off the main actor: nothing is asked of Apple, and the
/// whole results are not kept in memory, only what the report is made of.
nonisolated struct TestHealthReader: Sendable {
    var cache = BuildExtrasCache()

    @concurrent func report(workflowID: String, in snapshot: BuildSnapshot) async -> TestHealthReport {
        let runs = TestHealthReport.eligibleRuns(workflowID: workflowID, in: snapshot)
        var samples: [TestHealthReport.Sample] = []
        for run in runs {
            let extras = await cache.load(runID: run.id)
            if let sample = TestHealthReport.sample(of: run, actions: snapshot.actionsByRunID[run.id] ?? [], extras: extras) {
                samples.append(sample)
            }
        }
        return TestHealthReport(samples: samples, eligibleBuilds: runs.count)
    }

    /// One test over the last builds whose results are on disk, newest first until thirty are read. Nothing is asked of Apple.
    @concurrent func history(of identity: TestHistory.Identity, workflowID: String, in snapshot: BuildSnapshot) async -> TestHistory {
        let runs = TestHealthReport.eligibleRuns(workflowID: workflowID, in: snapshot)
        var entries: [TestHistory.Entry] = []
        for run in runs where entries.count < TestHistory.maxBuilds {
            let extras = await cache.load(runID: run.id)
            if let entry = TestHistory.entry(of: run, actions: snapshot.actionsByRunID[run.id] ?? [], extras: extras, identity: identity) {
                entries.append(entry)
            }
        }
        return TestHistory(identity: identity, entries: entries, eligibleBuilds: runs.count)
    }

    /// The newest builds whose test results are not on disk yet.
    @concurrent func runsToAnalyze(workflowID: String, in snapshot: BuildSnapshot, limit: Int) async -> [CIBuildRun] {
        var missing: [CIBuildRun] = []
        for run in TestHealthReport.eligibleRuns(workflowID: workflowID, in: snapshot) where missing.count < limit {
            if await cache.load(runID: run.id)?.testsComplete != true {
                missing.append(run)
            }
        }
        return missing
    }
}

/// The Tests section of a workflow sheet. It shows what is already known, and only fetches more when asked to,
/// one build after the other, saying how far it is and stopping when told or when the hour's requests run short.
@Observable
final class WorkflowTestsModel {
    static let batchSize = 10

    private(set) var report: TestHealthReport?
    private var reportWorkflowID: String?
    private(set) var progress: (done: Int, total: Int)?
    private(set) var stoppedForBudget = false
    private(set) var failureMessage: String?

    private let reader: TestHealthReader
    private let snapshot: @MainActor () -> BuildSnapshot
    /// Loads one build's test results, one action at a time; returns the reason when it could not.
    private let loadTests: @MainActor (CIBuildRun, [CIBuildAction]) async -> String?
    private let budget: @MainActor () async -> RateLimit?
    private var task: Task<Void, Never>?

    init(
        reader: TestHealthReader = TestHealthReader(),
        snapshot: @escaping @MainActor () -> BuildSnapshot,
        loadTests: @escaping @MainActor (CIBuildRun, [CIBuildAction]) async -> String?,
        budget: @escaping @MainActor () async -> RateLimit?
    ) {
        self.reader = reader
        self.snapshot = snapshot
        self.loadTests = loadTests
        self.budget = budget
    }

    var isAnalyzing: Bool { progress != nil }

    /// What is on disk, right now. No request.
    func refresh(workflowID: String) async {
        if reportWorkflowID != workflowID {
            // Another workflow's figures are never shown while this one's are read.
            report = nil
            stoppedForBudget = false
            failureMessage = nil
            reportWorkflowID = workflowID
        }
        let fresh = await reader.report(workflowID: workflowID, in: snapshot())
        if reportWorkflowID == workflowID {
            report = fresh
        }
    }

    /// What is on disk about one test, right now. No request.
    func history(of identity: TestHistory.Identity, workflowID: String) async -> TestHistory {
        await reader.history(of: identity, workflowID: workflowID, in: snapshot())
    }

    func startAnalysis(workflowID: String) {
        guard task == nil else { return }
        task = Task { [self] in
            await analyze(workflowID: workflowID)
            task = nil
        }
    }

    func stop() {
        task?.cancel()
    }

    func analyze(workflowID: String, limit: Int = WorkflowTestsModel.batchSize) async {
        guard progress == nil else { return }
        await refresh(workflowID: workflowID)
        stoppedForBudget = false
        failureMessage = nil
        let current = snapshot()
        let runs = await reader.runsToAnalyze(workflowID: workflowID, in: current, limit: limit)
        guard !runs.isEmpty else { return }
        progress = (0, runs.count)
        defer { progress = nil }
        for (index, run) in runs.enumerated() {
            if Task.isCancelled { break }
            if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining {
                stoppedForBudget = true
                break
            }
            if let failure = await loadTests(run, current.actionsByRunID[run.id] ?? []) {
                failureMessage = failure
                break
            }
            progress = (index + 1, runs.count)
            await refresh(workflowID: workflowID)
        }
        await refresh(workflowID: workflowID)
    }
}
