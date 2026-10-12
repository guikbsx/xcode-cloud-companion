import Foundation
import Observation

/// The menu's source of truth: shows the cached snapshot at once, then keeps it fresh in the background.
@Observable
final class BuildStore {
    private(set) var snapshot: BuildSnapshot = .empty
    private(set) var isSyncing = false
    private(set) var progress: String?
    private(set) var syncStartedAt: Date?
    private(set) var lastError: AppStoreConnectError?
    private(set) var isConfigured = false
    /// False until a first sync has looked for the key: before that, `isConfigured` says nothing yet.
    private(set) var hasAttemptedSync = false
    /// Apple's hourly request budget as of the last response, shared by the menu, the window and the details.
    private(set) var rateLimit: RateLimit?
    private(set) var windowIsOpen = false
    private(set) var screenIsLocked = false
    /// Called after each successful sync with the snapshot before and after it: what just changed is what notifications are made of.
    @ObservationIgnored var onSync: ((_ previous: BuildSnapshot, _ current: BuildSnapshot) -> Void)?

    private let credentialsStore: any CredentialsStore
    private let cacheStore: BuildCacheStore
    private let makeClient: (AppStoreConnectCredentials) -> AppStoreConnectClient
    private let now: () -> Date
    private var client: AppStoreConnectClient?
    private var consecutiveRateLimits = 0
    private var hasLoadedCache = false
    /// Workflow states Apple confirmed after a change made here, kept until a sync that began later has read them itself.
    private var confirmedWorkflowStates: [String: (isEnabled: Bool, at: Date)] = [:]
    private var loop: Task<Void, Never>?
    /// The account was removed: nothing is fetched or written any more.
    private var isRetired = false

    init(
        credentialsStore: any CredentialsStore = KeychainCredentialsStore(),
        cacheStore: BuildCacheStore = BuildCacheStore(),
        makeClient: @escaping (AppStoreConnectCredentials) -> AppStoreConnectClient = { AppStoreConnectClient(credentials: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentialsStore = credentialsStore
        self.cacheStore = cacheStore
        self.makeClient = makeClient
        self.now = now
    }

    var lastErrorMessage: String? {
        lastError?.message
    }

    /// Starts the refresh loop; calling it again restarts the loop with an immediate refresh.
    func start() {
        guard !isRetired else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.loadCacheIfNeeded()
            guard var outcome = await self?.synchronize() else { return }
            var lastRun = self?.now() ?? Date()
            // The pace depends on the budget, which changes between two syncs: it is judged every few seconds.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                if SyncSchedule.isDue(lastRun: lastRun, now: self.now(), outcome: outcome, context: self.syncContext) {
                    outcome = await self.synchronize()
                    lastRun = self.now()
                }
            }
        }
    }

    static let tick: Duration = .seconds(5)

    var syncContext: SyncContext {
        SyncContext(budget: rateLimit)
    }

    /// The window shows what is built right now: it asks for fresh data when the last sync is older than 30 seconds.
    func windowDidOpen() {
        windowIsOpen = true
        let isStale = snapshot.lastSuccessfulSync.map { now().timeIntervalSince($0) > 30 } ?? true
        if isStale, loop != nil {
            Task { await refreshNow() }
        }
    }

    func windowDidClose() {
        windowIsOpen = false
    }

    func screenLockDidChange(isLocked: Bool) {
        screenIsLocked = isLocked
        if !isLocked, loop != nil {
            let isStale = snapshot.lastSuccessfulSync.map { now().timeIntervalSince($0) > 60 } ?? true
            if isStale { Task { await refreshNow() } }
        }
    }

    /// A run just started from the app shows in the lists at once, before the next sync brings Apple's own copy.
    func insertStarted(_ run: CIBuildRun) {
        guard !snapshot.runs.contains(where: { $0.id == run.id }) else { return }
        snapshot.runs.insert(run, at: 0)
        // The new run is pending: the sync picks it up soon, without waiting for the idle pace.
        Task {
            try? await Task.sleep(for: .seconds(5))
            await refreshNow()
        }
    }

    /// A workflow was paused or resumed from the app: the lists show Apple's answer at once, and a sync already under way,
    /// which may have read the list before the change, does not undo it.
    func setWorkflowEnabled(_ isEnabled: Bool, workflowID: String) async {
        confirmedWorkflowStates[workflowID] = (isEnabled, now())
        applyConfirmedWorkflowStates(syncStartedAt: nil)
        guard !isRetired else { return }
        try? await cacheStore.save(snapshot)
    }

    /// A workflow changed from the app (name, Xcode, clean…): Apple's answer shows at once, and a sync that read the list
    /// before the change does not undo it.
    private var confirmedWorkflowEdits: [String: (workflow: CIWorkflow, at: Date)] = [:]

    func applyWorkflow(_ workflow: CIWorkflow) async {
        confirmedWorkflowEdits[workflow.id] = (workflow, now())
        applyConfirmedWorkflowStates(syncStartedAt: nil)
        guard !isRetired else { return }
        try? await cacheStore.save(snapshot)
    }

    private func applyConfirmedWorkflowStates(syncStartedAt: Date?) {
        if let syncStartedAt {
            confirmedWorkflowStates = confirmedWorkflowStates.filter { $0.value.at >= syncStartedAt }
            confirmedWorkflowEdits = confirmedWorkflowEdits.filter { $0.value.at >= syncStartedAt }
        }
        for index in snapshot.workflows.indices {
            let id = snapshot.workflows[index].id
            if let edit = confirmedWorkflowEdits[id] {
                snapshot.workflows[index].adopt(edit.workflow)
            }
            if let confirmed = confirmedWorkflowStates[id] {
                snapshot.workflows[index].isEnabled = confirmed.isEnabled
            }
        }
    }

    /// Reads the budget the client last saw; no request is made.
    func updateRateLimit() async {
        if let limit = await client?.rateLimit() {
            rateLimit = limit
        }
    }

    /// Stops refreshing, for instance while the Mac sleeps.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Stops for good, and waits for a sync under way to end: once it returns, the account's cache can be deleted
    /// without anything writing it back.
    func retire() async {
        isRetired = true
        let running = loop
        stop()
        await running?.value
        while isSyncing {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func refreshNow() async {
        _ = await synchronize()
    }

    func credentialsDidChange() async {
        client = nil
        lastError = nil
        consecutiveRateLimits = 0
        if (try? await credentialsStore.load()) == nil {
            snapshot = .empty
            isConfigured = false
            await cacheStore.delete()
        }
        start()
    }

    func loadCacheIfNeeded() async {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        if let cached = await cacheStore.load() {
            snapshot = cached
        }
    }

    @discardableResult
    func synchronize() async -> SyncOutcome {
        guard !isSyncing else { return .succeeded(hasActiveBuilds: snapshot.hasActiveBuilds) }
        guard !isRetired else { return .notConfigured }
        isSyncing = true
        hasAttemptedSync = true
        syncStartedAt = now()
        defer {
            isSyncing = false
            progress = nil
        }

        guard let client = await currentClient() else {
            isConfigured = false
            return .notConfigured
        }
        isConfigured = true

        defer { Task { await updateRateLimit() } }
        do {
            var synchronizer = BuildSynchronizer(client: client)
            synchronizer.progress = { [weak self] text in
                Task { @MainActor in self?.progress = text }
            }
            let previous = snapshot
            let startedAt = now()
            let synced = try await synchronizer.sync(from: previous, now: startedAt)
            guard !isRetired else { return .notConfigured }
            snapshot = synced
            applyConfirmedWorkflowStates(syncStartedAt: startedAt)
            onSync?(previous, snapshot)
            lastError = nil
            consecutiveRateLimits = 0
            try? await cacheStore.save(snapshot)
            // Test results still to fetch are picked up quickly, like a running build would be.
            let hasMoreToFetch = BuildSynchronizer.pendingTestResultCount(in: snapshot) > 0
            return .succeeded(hasActiveBuilds: snapshot.hasActiveBuilds || hasMoreToFetch)
        } catch .rateLimited {
            lastError = .rateLimited
            consecutiveRateLimits += 1
            return .rateLimited(consecutive: consecutiveRateLimits)
        } catch {
            lastError = error
            return .failed
        }
    }

    func hasCredentials() async -> Bool {
        if client != nil { return true }
        return (try? await credentialsStore.load()) != nil
    }

    /// The client the window's detail views fetch through; nil while no key is stored.
    func detailClient() async -> AppStoreConnectClient? {
        await currentClient()
    }

    private func currentClient() async -> AppStoreConnectClient? {
        if let client { return client }
        guard let stored = try? await credentialsStore.load(),
              let credentials = try? stored.credentials()
        else { return nil }
        let client = makeClient(credentials)
        self.client = client
        return client
    }
}

extension BuildStore: RefreshableSync {
    var lastSuccessfulSync: Date? { snapshot.lastSuccessfulSync }
}
