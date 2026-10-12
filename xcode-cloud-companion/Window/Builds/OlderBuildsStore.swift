import Foundation
import Observation

/// Builds older than the cache's window, read page by page when the user reaches the foot of the list. They stay out of
/// the snapshot: the cycle's minutes are never computed from them, and nothing of them is written to disk.
@Observable
final class OlderBuildsStore {
    static let pageSize = 100
    /// A click reads this many pages at most, when the first ones only repeat builds the cache already holds.
    static let pagesPerLoad = 3

    private(set) var runs: [CIBuildRun] = []
    private(set) var loading: Set<String> = []
    /// Products whose last page was read.
    private(set) var exhausted: Set<String> = []
    private(set) var lastError: String?
    private var nextPages: [String: URL] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let budget: () async -> RateLimit?

    init(client: @escaping () async -> AppStoreConnectClient?, budget: @escaping () async -> RateLimit?) {
        self.client = client
        self.budget = budget
    }

    func runs(forProductID productID: String) -> [CIBuildRun] {
        runs.filter { $0.productID == productID }
    }

    func isLoading(_ productID: String) -> Bool {
        loading.contains(productID)
    }

    func isExhausted(_ productID: String) -> Bool {
        exhausted.contains(productID)
    }

    /// Reads the next page of a product's builds, one request at a time and never again after a 429. `known` are the
    /// builds already shown, so a page that only repeats them is followed by the next one.
    func loadOlder(productID: String, known: [CIBuildRun]) async {
        guard !loading.contains(productID), !exhausted.contains(productID) else { return }
        guard let client = await client() else { return }
        if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining {
            lastError = String(localized: "Apple’s hourly request limit is nearly spent: older builds wait for the next hour.")
            return
        }
        loading.insert(productID)
        defer { loading.remove(productID) }
        lastError = nil
        var knownIDs = Set(known.map(\.id)).union(runs.map(\.id))
        var url = nextPages[productID] ?? AppStoreConnectEndpoint.buildRuns(productID: productID, pageSize: Self.pageSize)
        for _ in 0..<Self.pagesPerLoad {
            let page: JSONAPIDocument<CIBuildRunAttributes>
            do {
                page = try await client.document(at: url)
            } catch {
                lastError = error.message
                return
            }
            let fresh = page.buildRuns(productID: productID).filter { !knownIDs.contains($0.id) }
            knownIDs.formUnion(fresh.map(\.id))
            runs.append(contentsOf: fresh)
            guard let next = page.links?.next, AppStoreConnectEndpoint.isTrusted(next) else {
                exhausted.insert(productID)
                nextPages.removeValue(forKey: productID)
                return
            }
            nextPages[productID] = next
            url = next
            if !fresh.isEmpty { return }
        }
    }
}
