import Foundation

nonisolated struct BuildSnapshot: Codable, Sendable, Equatable {
    var products: [CIProduct] = []
    /// Newest first, per product order of the API.
    var runs: [CIBuildRun] = []
    var actionsByRunID: [String: [CIBuildAction]] = [:]
    /// Per-device test time of each completed test action, the basis of Apple's per-machine billing.
    var testDevicesByActionID: [String: [CITestDeviceRun]] = [:]
    var workflows: [CIWorkflow] = []
    var lastSuccessfulSync: Date?

    static let empty = BuildSnapshot()

    init(
        products: [CIProduct] = [],
        runs: [CIBuildRun] = [],
        actionsByRunID: [String: [CIBuildAction]] = [:],
        testDevicesByActionID: [String: [CITestDeviceRun]] = [:],
        workflows: [CIWorkflow] = [],
        lastSuccessfulSync: Date? = nil
    ) {
        self.products = products
        self.runs = runs
        self.actionsByRunID = actionsByRunID
        self.testDevicesByActionID = testDevicesByActionID
        self.workflows = workflows
        self.lastSuccessfulSync = lastSuccessfulSync
    }

    // Caches written before a field existed still load: the missing data is fetched on the next sync.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        products = try container.decodeIfPresent([CIProduct].self, forKey: .products) ?? []
        runs = try container.decodeIfPresent([CIBuildRun].self, forKey: .runs) ?? []
        actionsByRunID = try container.decodeIfPresent([String: [CIBuildAction]].self, forKey: .actionsByRunID) ?? [:]
        testDevicesByActionID = try container.decodeIfPresent([String: [CITestDeviceRun]].self, forKey: .testDevicesByActionID) ?? [:]
        workflows = try container.decodeIfPresent([CIWorkflow].self, forKey: .workflows) ?? []
        lastSuccessfulSync = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSync)
    }

    var hasActiveBuilds: Bool {
        runs.contains { $0.executionProgress != .complete }
    }

    func runs(forProductID productID: String) -> [CIBuildRun] {
        runs.filter { $0.productID == productID }
    }

    func workflow(id: String?) -> CIWorkflow? {
        id.flatMap { id in workflows.first { $0.id == id } }
    }
}

/// The cache lives in the app's sandbox container; it only holds what the menu shows.
nonisolated struct BuildCacheStore: Sendable {
    var fileURL: URL = .applicationSupportDirectory.appending(path: "BuildCache.json")

    @concurrent func load() async -> BuildSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BuildSnapshot.self, from: data)
    }

    @concurrent func save(_ snapshot: BuildSnapshot) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    @concurrent func delete() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
