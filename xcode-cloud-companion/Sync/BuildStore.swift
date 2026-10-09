import Foundation
import Observation

/// The menu's source of truth: shows the cached snapshot at once, then keeps it fresh in the background.
@Observable
final class BuildStore {
    private(set) var snapshot: BuildSnapshot = .empty
    private(set) var isSyncing = false
    private(set) var progress: String?
    private(set) var lastError: AppStoreConnectError?
    private(set) var isConfigured = false

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
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.synchronize()
                try? await Task.sleep(for: SyncSchedule.delay(after: outcome))
            }
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
        defer {
            isSyncing = false
            progress = nil
        }

        guard let client = await currentClient() else {
            isConfigured = false
            return .notConfigured
        }
        isConfigured = true

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
