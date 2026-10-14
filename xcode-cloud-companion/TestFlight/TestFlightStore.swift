import Foundation
import Observation

/// Every app's last reading, in one file of the account's folder: it goes with the account.
nonisolated struct TestFlightFile: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var schemaVersion = TestFlightFile.currentVersion
    /// By Xcode Cloud product.
    var readings: [String: TestFlightReading] = [:]
}

nonisolated struct TestFlightCache: Sendable {
    var fileURL: URL

    @concurrent func load() async -> TestFlightFile? {
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(TestFlightFile.self, from: data),
              file.schemaVersion == TestFlightFile.currentVersion
        else { return nil }
        return file
    }

    @concurrent func save(_ file: TestFlightFile) async {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: fileURL, options: [.atomic])
    }

    @concurrent func delete() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The TestFlight builds of the account's apps: asked for after a sync that succeeded, when the pace of `TestFlightCadence`
/// allows it, and kept in the account's folder with the times Cumulus saw a build change. Cumulus Pro: without it nothing
/// is asked. A key that Apple says cannot read TestFlight is not asked again until the app is restarted.
@Observable
final class TestFlightStore {
    private(set) var readings: [String: TestFlightReading] = [:]
    /// The products being read right now.
    private(set) var reading: Set<String> = []
    /// Apple answered 403: the key cannot read TestFlight.
    private(set) var isForbidden = false
    /// Called with each read, once it is kept: the banners come from it.
    @ObservationIgnored var onRead: ((_ app: TestFlightApp, _ builds: [TestFlightBuild]) -> Void)?
    /// Cumulus Pro, and an active account: false reads nothing.
    @ObservationIgnored var allowed: @MainActor () -> Bool = { true }

    private let cache: TestFlightCache
    private let client: () async -> AppStoreConnectClient?
    private let budget: () async -> RateLimit?
    private let now: () -> Date
    private var hasLoadedCache = false
    private var isSyncing = false
    private var failures: [String: Date] = [:]

    init(
        cache: TestFlightCache, client: @escaping () async -> AppStoreConnectClient?, budget: @escaping () async -> RateLimit?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.cache = cache
        self.client = client
        self.budget = budget
        self.now = now
    }

    func reading(for productID: String) -> TestFlightReading? {
        readings[productID]
    }

    func isReading(_ productID: String) -> Bool {
        reading.contains(productID)
    }

    /// A build of any app, with what Cumulus saw of it.
    func lookup(buildID: String) -> (build: TestFlightBuild, observation: TestFlightObservation?)? {
        for reading in readings.values {
            if let build = reading.build(id: buildID) { return (build, reading.observations[buildID]) }
        }
        return nil
    }

    /// Brings back what the last session read, so that nothing is asked again before its time.
    func loadCache() async {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        if let file = await cache.load(), readings.isEmpty {
            readings = file.readings
        }
    }

    /// Asks for the apps whose turn it is. Called after each sync that succeeded; one request per app that is due.
    func sync(snapshot: BuildSnapshot) async {
        guard allowed() else { return }
        await loadCache()
        guard !isForbidden, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let apps = TestFlightApp.shipping(in: snapshot)
        let remaining = await budget()?.remaining
        for app in apps {
            let moment = now()
            guard TestFlightCadence.isDue(
                app: app, reading: readings[app.productID], lastFailure: failures[app.productID], now: moment, remainingRequests: remaining
            ) else { continue }
            guard let client = await client() else { return }
            reading.insert(app.productID)
            defer { reading.remove(app.productID) }
            do {
                let builds = try await client.testFlightBuilds(appID: app.appID)
                readings[app.productID] = TestFlightReading.following(readings[app.productID], appID: app.appID, builds: builds, at: now())
                failures[app.productID] = nil
                await cache.save(TestFlightFile(readings: readings))
                onRead?(app, builds)
            } catch .forbidden {
                isForbidden = true
                return
            } catch .rateLimited {
                failures[app.productID] = now()
                return
            } catch {
                failures[app.productID] = now()
            }
        }
    }

    /// The key was reset or the account removed: what was read goes, and the next key is asked again.
    func reset() async {
        readings = [:]
        failures = [:]
        isForbidden = false
        await cache.delete()
    }
}
