import Foundation

/// What the socket needs from the sync: `BuildStore` in the app, a stand-in in tests.
@MainActor
protocol RefreshableSync: AnyObject, Sendable {
    var lastSuccessfulSync: Date? { get }
    var isSyncing: Bool { get }
    func hasCredentials() async -> Bool
    func synchronize() async -> SyncOutcome
}

nonisolated extension SyncOutcome {
    var ipcName: String {
        switch self {
        case .succeeded: "succeeded"
        case .rateLimited: "rateLimited"
        case .failed: "failed"
        case .notConfigured: "notConfigured"
        }
    }
}

/// Answers the `cumulus` command from the running app. Only the calls into the stores hop to the main actor.
nonisolated struct AppIPCService: IPCService {
    /// A sync this recent is not asked again: an agent in a loop must not drain the key's hourly budget.
    static let recentSync = AppIPCRefresh.recentSync
    static let pollInterval: Duration = .milliseconds(200)

    let sync: any RefreshableSync
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var now: @Sendable () -> Date = { Date() }
    var openBuild: @MainActor @Sendable (String) -> Void = { _ in }
    /// Loads a build's details into the cache; false when the build is unknown, still running, or Apple refused.
    var loadBuildDetails: @MainActor @Sendable (String) async -> Bool = { _ in false }

    func ping() async -> IPCResult {
        let hasCredentials = await sync.hasCredentials()
        return await IPCResult(appVersion: appVersion, lastSuccessfulSync: sync.lastSuccessfulSync, isSyncing: sync.isSyncing, hasCredentials: hasCredentials)
    }

    func refresh(wait: Bool) async -> IPCResult {
        guard await sync.hasCredentials() else {
            return await IPCResult(lastSuccessfulSync: sync.lastSuccessfulSync, accepted: false, reason: IPCRefreshReason.noCredentials)
        }
        if await sync.isSyncing {
            if wait { await waitForSyncToEnd() }
            return await IPCResult(lastSuccessfulSync: sync.lastSuccessfulSync, accepted: false, reason: IPCRefreshReason.syncing)
        }
        if let last = await sync.lastSuccessfulSync, now().timeIntervalSince(last) < Self.recentSync {
            return IPCResult(lastSuccessfulSync: last, accepted: false, reason: IPCRefreshReason.recent)
        }
        guard wait else {
            Task { await sync.synchronize() }
            return await IPCResult(lastSuccessfulSync: sync.lastSuccessfulSync, accepted: true)
        }
        let outcome = await sync.synchronize()
        return await IPCResult(lastSuccessfulSync: sync.lastSuccessfulSync, accepted: true, outcome: outcome.ipcName)
    }

    func open(buildRunID: String) async -> IPCResult {
        await openBuild(buildRunID)
        return IPCResult(opened: true)
    }

    func loadDetails(buildRunID: String) async -> IPCResult {
        IPCResult(loaded: await loadBuildDetails(buildRunID))
    }

    private func waitForSyncToEnd() async {
        while await sync.isSyncing {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

/// Fetches a finished build's issues, tests and artifacts the way its sheet does, for a build nobody opened in the window.
@MainActor
struct BuildDetailsLoader {
    let buildStore: BuildStore
    let extrasStore: BuildExtrasStore

    func load(_ buildRunID: String) async -> Bool {
        await buildStore.loadCacheIfNeeded()
        guard let run = buildStore.snapshot.runs.first(where: { $0.id == buildRunID }), run.executionProgress == .complete else { return false }
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        await extrasStore.loadBetaBuilds(for: run)
        await extrasStore.loadIssues(for: run, actions: actions)
        await extrasStore.loadTests(for: run, actions: actions)
        await extrasStore.loadArtifacts(for: run, actions: actions)
        let parts: [BuildExtrasStore.Part] = [.issues, .tests, .artifacts]
        return parts.allSatisfy { extrasStore.state($0, runID: run.id) == .loaded }
    }
}
