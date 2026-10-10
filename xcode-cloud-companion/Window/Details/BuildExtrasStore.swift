import Foundation
import Observation

/// What a build sheet fetches on demand, beyond the snapshot. Each part is empty until it has been loaded.
nonisolated struct BuildExtras: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var schemaVersion: Int? = BuildExtras.currentVersion
    var betaBuilds: [CIBetaBuild]?
    var issuesByAction: [String: [CIIssue]] = [:]
    var testsByAction: [String: [CITestResult]] = [:]
    var artifactsByAction: [String: [CIArtifact]] = [:]
    var issuesComplete = false
    var testsComplete = false
    var artifactsComplete = false
}

/// One file per finished build in the app group container: a build that is `COMPLETE` never changes, so it is asked for once.
nonisolated struct BuildExtrasCache: Sendable {
    var directory: URL = AccountPaths.first.buildDetails

    private func fileURL(_ runID: String) -> URL {
        directory.appending(path: "\(runID).json")
    }

    @concurrent func load(runID: String) async -> BuildExtras? {
        guard Self.isSafe(runID), let data = try? Data(contentsOf: fileURL(runID)),
              let extras = try? JSONDecoder().decode(BuildExtras.self, from: data),
              extras.schemaVersion == BuildExtras.currentVersion
        else { return nil }
        return extras
    }

    @concurrent func save(_ extras: BuildExtras, runID: String) async {
        guard Self.isSafe(runID) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(extras).write(to: fileURL(runID), options: [.atomic])
    }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isSafe(_ runID: String) -> Bool {
        !runID.isEmpty && runID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

enum ExtrasLoadState: Equatable {
    case idle
    case loading(done: Int, total: Int)
    case failed(message: String, done: Int, total: Int)
    case loaded
}

/// Loads the extras of the build on screen: from disk when it is finished and already known, from Apple otherwise.
@Observable
final class BuildExtrasStore {
    enum Part {
        case issues, tests, artifacts
    }

    private(set) var extrasByRunID: [String: BuildExtras] = [:]
    private(set) var loadingRunIDs: Set<String> = []
    private(set) var states: [String: ExtrasLoadState] = [:]
    private let cache: BuildExtrasCache
    private let client: () async -> AppStoreConnectClient?

    init(cache: BuildExtrasCache = BuildExtrasCache(), client: @escaping () async -> AppStoreConnectClient?) {
        self.cache = cache
        self.client = client
    }

    func extras(for runID: String) -> BuildExtras? {
        extrasByRunID[runID]
    }

    func isLoading(_ runID: String) -> Bool {
        loadingRunIDs.contains(runID)
    }

    func state(_ part: Part, runID: String) -> ExtrasLoadState {
        states[key(part, runID)] ?? .idle
    }

    /// Brings back what is on disk for a finished build, without asking Apple anything.
    func loadCached(_ run: CIBuildRun) async {
        guard run.executionProgress == .complete else { return }
        _ = await restoreFromDisk(run.id)
    }

    /// TestFlight builds of the run. A finished run already known is not asked for again; a running one always is.
    func loadBetaBuilds(for run: CIBuildRun) async {
        let isFinished = run.executionProgress == .complete
        if isFinished, extrasByRunID[run.id]?.betaBuilds != nil { return }
        guard !loadingRunIDs.contains(run.id) else { return }
        loadingRunIDs.insert(run.id)
        defer { loadingRunIDs.remove(run.id) }

        if isFinished, await restoreFromDisk(run.id), extrasByRunID[run.id]?.betaBuilds != nil { return }
        guard let client = await client(), let betaBuilds = try? await client.betaBuilds(buildRunID: run.id) else { return }
        var extras = extrasByRunID[run.id] ?? BuildExtras()
        extras.betaBuilds = betaBuilds
        extrasByRunID[run.id] = extras
        if isFinished { await cache.save(extras, runID: run.id) }
    }

    /// Problems of every action that may have some: one request per action, results kept as they arrive.
    func loadIssues(for run: CIBuildRun, actions: [CIBuildAction]) async {
        let wanted = actions.filter { ($0.issueCounts?.total ?? 1) > 0 }
        await load(.issues, run: run, actions: wanted) { (client, action) async throws(AppStoreConnectError) in
            let issues = try await client.issues(buildActionID: action.id)
            self.update(run.id) { $0.issuesByAction[action.id] = issues }
        } isDone: { extras, action in
            extras.issuesByAction[action.id] != nil
        } markComplete: {
            $0.issuesComplete = true
        } isComplete: {
            $0.issuesComplete
        }
    }

    /// Test results of every test action that finished, one request per action and page of 200.
    func loadTests(for run: CIBuildRun, actions: [CIBuildAction]) async {
        let wanted = actions.filter { $0.actionType == .test && $0.executionProgress == .complete }
        await load(.tests, run: run, actions: wanted) { (client, action) async throws(AppStoreConnectError) in
            let results = try await client.testResults(buildActionID: action.id)
            self.update(run.id) { $0.testsByAction[action.id] = results }
        } isDone: { extras, action in
            extras.testsByAction[action.id] != nil
        } markComplete: {
            $0.testsComplete = true
        } isComplete: {
            $0.testsComplete
        }
    }

    /// Files produced by every finished action, listed without their download addresses.
    func loadArtifacts(for run: CIBuildRun, actions: [CIBuildAction]) async {
        let wanted = actions.filter { $0.executionProgress == .complete }
        await load(.artifacts, run: run, actions: wanted) { (client, action) async throws(AppStoreConnectError) in
            let artifacts = try await client.artifacts(buildActionID: action.id)
            self.update(run.id) { $0.artifactsByAction[action.id] = artifacts }
        } isDone: { extras, action in
            extras.artifactsByAction[action.id] != nil
        } markComplete: {
            $0.artifactsComplete = true
        } isComplete: {
            $0.artifactsComplete
        }
    }

    // MARK: - Private

    private func key(_ part: Part, _ runID: String) -> String {
        "\(part)-\(runID)"
    }

    private func update(_ runID: String, _ change: (inout BuildExtras) -> Void) {
        var extras = extrasByRunID[runID] ?? BuildExtras()
        change(&extras)
        extrasByRunID[runID] = extras
    }

    private func restoreFromDisk(_ runID: String) async -> Bool {
        guard extrasByRunID[runID] == nil, let stored = await cache.load(runID: runID) else { return extrasByRunID[runID] != nil }
        extrasByRunID[runID] = stored
        return true
    }

    private func load(
        _ part: Part, run: CIBuildRun, actions: [CIBuildAction],
        fetch: (AppStoreConnectClient, CIBuildAction) async throws(AppStoreConnectError) -> Void,
        isDone: (BuildExtras, CIBuildAction) -> Bool,
        markComplete: (inout BuildExtras) -> Void,
        isComplete: (BuildExtras) -> Bool
    ) async {
        let stateKey = key(part, run.id)
        if case .loading = states[stateKey] { return }
        let isFinished = run.executionProgress == .complete
        if isFinished { _ = await restoreFromDisk(run.id) }
        if isFinished, let known = extrasByRunID[run.id], isComplete(known) {
            states[stateKey] = .loaded
            return
        }
        // A running build changes: what was read earlier is read again.
        if !isFinished { update(run.id) { $0 = BuildExtras(betaBuilds: $0.betaBuilds) } }

        let pending = actions.filter { !isDone(extrasByRunID[run.id] ?? BuildExtras(), $0) }
        let total = actions.count
        var done = total - pending.count
        states[stateKey] = .loading(done: done, total: total)
        guard let client = await client() else {
            states[stateKey] = .failed(message: String(localized: "No API key is set up."), done: done, total: total)
            return
        }
        for action in pending {
            do {
                try await fetch(client, action)
                done += 1
                states[stateKey] = .loading(done: done, total: total)
            } catch {
                states[stateKey] = .failed(message: error.message, done: done, total: total)
                return
            }
        }
        update(run.id, markComplete)
        states[stateKey] = .loaded
        if isFinished, let extras = extrasByRunID[run.id] { await cache.save(extras, runID: run.id) }
    }
}
