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
    /// Apple's hourly request budget as of the last response, shared by the menu, the window and the details.
    private(set) var rateLimit: RateLimit?
    private(set) var windowIsOpen = false
    private(set) var screenIsLocked = false

    private let credentialsStore: any CredentialsStore
    private let cacheStore: BuildCacheStore
    private let makeClient: (AppStoreConnectCredentials) -> AppStoreConnectClient
    private let now: () -> Date
    private var client: AppStoreConnectClient?
    private var consecutiveRateLimits = 0
    private var hasLoadedCache = false
    private var loop: Task<Void, Never>?

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
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.loadCacheIfNeeded()
            guard var outcome = await self?.synchronize() else { return }
            var lastRun = self?.now() ?? Date()
            // The pace depends on the window, the lock and the budget, which change between two syncs: it is judged every few seconds.
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
        SyncContext(windowIsOpen: windowIsOpen, screenIsLocked: screenIsLocked, budget: rateLimit)
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
        isSyncing = true
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
            snapshot = try await synchronizer.sync(from: snapshot, now: now())
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
