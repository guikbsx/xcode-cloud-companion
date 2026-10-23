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

    /// The sync of an account, of the one on screen when no id is given; nil when the app has no such account.
    let sync: @MainActor @Sendable (_ accountID: String?) -> (any RefreshableSync)?
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var now: @Sendable () -> Date = { Date() }
    var openBuild: @MainActor @Sendable (String) -> Void = { _ in }
    /// Loads a build's details into the cache; false when the build is unknown, still running, or Apple refused.
    var loadBuildDetails: @MainActor @Sendable (String) async -> Bool = { _ in false }
    /// Starts a build for the command; `AgentLaunchService` in the app.
    var launchBuild: @MainActor @Sendable (IPCLaunchRequest) async -> IPCResult = { _ in IPCResult(reason: IPCLaunchReason.failed, launched: false) }
    /// Reads a build's TestFlight build and the groups of its app into the shared folder; `AgentTestFlightService` in the app.
    var loadTestFlight: @MainActor @Sendable (String) async -> IPCResult = { _ in IPCResult(loaded: false) }
    /// Gives a TestFlight build to groups and takes it from others for the command.
    var giveTestFlight: @MainActor @Sendable (IPCTestFlightGiveRequest) async -> IPCResult = { _ in IPCResult(reason: IPCTestFlightReason.failed, written: false) }
    /// Expires a TestFlight build for the command.
    var expireTestFlight: @MainActor @Sendable (IPCTestFlightExpireRequest) async -> IPCResult = { _ in IPCResult(reason: IPCTestFlightReason.failed, written: false) }

    func ping(accountID: String?) async -> IPCResult {
        guard let sync = await sync(accountID) else {
            return IPCResult(appVersion: appVersion, isSyncing: false, hasCredentials: false)
        }
        let hasCredentials = await sync.hasCredentials()
        return await IPCResult(appVersion: appVersion, lastSuccessfulSync: sync.lastSuccessfulSync, isSyncing: sync.isSyncing, hasCredentials: hasCredentials)
    }

    func refresh(wait: Bool, accountID: String?) async -> IPCResult {
        guard let sync = await sync(accountID) else {
            // Without any account the app has no key; a named account that is gone was removed since the command listed it.
            return IPCResult(accepted: false, reason: accountID == nil ? IPCRefreshReason.noCredentials : IPCRefreshReason.unknownAccount)
        }
        guard await sync.hasCredentials() else {
            return await IPCResult(lastSuccessfulSync: sync.lastSuccessfulSync, accepted: false, reason: IPCRefreshReason.noCredentials)
        }
        if await sync.isSyncing {
            if wait { await waitForSyncToEnd(sync) }
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

    func launch(_ request: IPCLaunchRequest) async -> IPCResult {
        await launchBuild(request)
    }

    func testFlightLoad(buildRunID: String) async -> IPCResult {
        await loadTestFlight(buildRunID)
    }

    func testFlightGive(_ request: IPCTestFlightGiveRequest) async -> IPCResult {
        await giveTestFlight(request)
    }

    func testFlightExpire(_ request: IPCTestFlightExpireRequest) async -> IPCResult {
        await expireTestFlight(request)
    }

    private func waitForSyncToEnd(_ sync: any RefreshableSync) async {
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
