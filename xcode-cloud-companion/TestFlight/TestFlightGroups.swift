import Foundation
import Observation

nonisolated struct BetaGroupAttributes: Decodable, Sendable {
    let name: String?
    let isInternalGroup: Bool?
    let hasAccessToAllBuilds: Bool?
    let publicLinkEnabled: Bool?
}

nonisolated extension JSONAPIDocument where Attributes == BetaGroupAttributes {
    /// Internal groups first, each part by name. A group Apple gave no name to is left out.
    var betaGroups: [BetaGroup] {
        let groups = data.compactMap { resource -> BetaGroup? in
            guard let name = resource.attributes?.name else { return nil }
            let isInternal = resource.attributes?.isInternalGroup ?? false
            return BetaGroup(
                id: resource.id, name: name, isInternal: isInternal,
                receivesEveryBuild: isInternal && resource.attributes?.hasAccessToAllBuilds == true, testerCount: nil
            )
        }
        let byName: (BetaGroup, BetaGroup) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return groups.filter(\.isInternal).sorted(by: byName) + groups.filter { !$0.isInternal }.sorted(by: byName)
    }
}

/// A page of a group's testers: only the number matters.
nonisolated struct BetaTesterPage: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        struct Paging: Decodable, Sendable {
            let total: Int?
        }

        let paging: Paging?
    }

    let data: [JSONAPIResourceIdentifier]?
    let links: JSONAPIDocument<BetaGroupAttributes>.Links?
    let meta: Meta?

    /// Apple's total; failing that, the identifiers of a page that is the last. Nil when neither tells.
    var count: Int? {
        if let total = meta?.paging?.total { return total }
        return links?.next == nil ? data?.count : nil
    }
}

extension AppStoreConnectClient {
    /// The groups of an app, internal first.
    func betaGroups(appID: String) async throws(AppStoreConnectError) -> [BetaGroup] {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.betaGroups(appID: appID), of: BetaGroupAttributes.self, maxPages: 2)
        return pages.flatMap(\.betaGroups)
    }

    /// How many testers a group has: one request, which asks for identifiers only.
    func betaTesterCount(groupID: String) async throws(AppStoreConnectError) -> Int? {
        let page: BetaTesterPage = try await decoded(at: AppStoreConnectEndpoint.betaGroupTesters(groupID: groupID))
        return page.count
    }
}

/// The groups of the apps that hand builds to TestFlight, read for the card that gives a build to them. Each app is read
/// once a session, and its testers counted once a session, group by group: the file in the account's folder only lets the
/// card draw at once. A key that Apple says cannot read them is not asked again.
@Observable
final class TestFlightGroupsStore {
    private(set) var readings: [String: BetaGroupsReading] = [:]
    /// The apps whose groups are being read right now.
    private(set) var reading: Set<String> = []
    /// The apps whose first read ended this session, with groups or without: what the skeleton waits for.
    private(set) var attempted: Set<String> = []
    private(set) var isForbidden = false

    private let cache: BetaGroupsCache
    private let client: () async -> AppStoreConnectClient?
    private let budget: () async -> RateLimit?
    private let now: () -> Date
    private var hasLoadedCache = false
    private var loaded: Set<String> = []
    private var failures: [String: Date] = [:]

    /// A failed read is not asked again before this long.
    static let retryInterval: TimeInterval = 15 * 60

    init(
        cache: BetaGroupsCache, client: @escaping () async -> AppStoreConnectClient?, budget: @escaping () async -> RateLimit?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.cache = cache
        self.client = client
        self.budget = budget
        self.now = now
    }

    func groups(for appID: String) -> [BetaGroup]? {
        readings[appID]?.groups
    }

    func hasAttempted(_ appID: String) -> Bool {
        attempted.contains(appID)
    }

    /// Brings back what the last session read, so that the card draws before Apple answers.
    func loadCache() async {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        if let file = await cache.load(), readings.isEmpty {
            readings = file.readings
        }
    }

    /// Reads the groups of an app once this session, then the tester count of each; nothing when the key's budget is nearly spent.
    func load(appID: String) async {
        await loadCache()
        guard !loaded.contains(appID), !reading.contains(appID), !isForbidden else {
            attempted.insert(appID)
            return
        }
        if let failure = failures[appID], now().timeIntervalSince(failure) < Self.retryInterval {
            attempted.insert(appID)
            return
        }
        if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining {
            attempted.insert(appID)
            return
        }
        guard let client = await client() else {
            attempted.insert(appID)
            return
        }
        reading.insert(appID)
        defer {
            reading.remove(appID)
            attempted.insert(appID)
        }
        do {
            var groups = try await client.betaGroups(appID: appID)
            let known = Dictionary(readings[appID]?.groups.map { ($0.id, $0.testerCount) } ?? [], uniquingKeysWith: { first, _ in first })
            for index in groups.indices {
                groups[index].testerCount = known[groups[index].id] ?? nil
            }
            readings[appID] = BetaGroupsReading(appID: appID, groups: groups, readAt: now())
            loaded.insert(appID)
            failures[appID] = nil
            await countTesters(appID: appID, client: client)
            await cache.save(BetaGroupsFile(readings: readings))
        } catch .forbidden {
            isForbidden = true
        } catch {
            failures[appID] = now()
        }
    }

    private func countTesters(appID: String, client: AppStoreConnectClient) async {
        guard let groups = readings[appID]?.groups else { return }
        for group in groups {
            do {
                let count = try await client.betaTesterCount(groupID: group.id)
                guard var reading = readings[appID], let index = reading.groups.firstIndex(where: { $0.id == group.id }) else { continue }
                reading.groups[index].testerCount = count
                readings[appID] = reading
            } catch .rateLimited, .forbidden {
                return
            } catch {
                continue
            }
        }
    }

    /// The key was reset or the account removed: what was read goes, and the next key is asked again.
    func reset() async {
        readings = [:]
        attempted = []
        loaded = []
        failures = [:]
        isForbidden = false
        await cache.delete()
    }
}
