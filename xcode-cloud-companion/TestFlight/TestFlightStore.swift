import Foundation
import Observation

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
    /// The apps as the last sync named them, for the banners a read of one build may bring.
    private var apps: [String: TestFlightApp] = [:]

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

    /// The builds the last read named for an App Store Connect app, newest first.
    func builds(forAppID appID: String) -> [TestFlightBuild] {
        readings.values.first { $0.appID == appID }?.builds ?? []
    }

    /// The App Store Connect app a known build belongs to.
    func appID(ofBuild buildID: String) -> String? {
        readings.values.first { $0.build(id: buildID) != nil }?.appID
    }

    /// Reads one build again, whatever the pace: what a distribution did. It replaces the build in its app's reading, or joins
    /// it, and dates what changed like any other read. Nothing is asked without Cumulus Pro, for a key that cannot read
    /// TestFlight, or for a build no reading knows. Returns the build as Apple has it; nil when it could not be read.
    func reread(buildID: String) async -> TestFlightBuild? {
        guard allowed(), !isForbidden, let productID = readings.first(where: { $0.value.build(id: buildID) != nil })?.key,
              let known = readings[productID], let client = await client()
        else { return nil }
        reading.insert(productID)
        defer { reading.remove(productID) }
        guard let build = try? await client.testFlightBuild(id: buildID) else { return nil }
        var builds = known.builds.filter { $0.id != buildID } + [build]
        builds.sort { ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast) }
        readings[productID] = TestFlightReading.following(known, appID: known.appID, builds: builds, at: now())
        await cache.save(TestFlightFile(readings: readings))
        if let app = apps[productID] { onRead?(app, builds) }
        return build
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
        self.apps = Dictionary(apps.map { ($0.productID, $0) }, uniquingKeysWith: { first, _ in first })
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
