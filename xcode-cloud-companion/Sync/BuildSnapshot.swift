import Foundation

nonisolated struct BuildSnapshot: Codable, Sendable, Equatable {
    var products: [CIProduct] = []
    /// Newest first, per product order of the API.
    var runs: [CIBuildRun] = []
    var actionsByRunID: [String: [CIBuildAction]] = [:]
    /// Per-device test time of each completed test action, the basis of Apple's per-machine billing.
    var testDevicesByActionID: [String: [CITestDeviceRun]] = [:]
    /// Failed attempts to fetch an action's results: after three, Apple is taken to refuse them and the action is left alone.
    var testResultAttempts: [String: Int] = [:]
    var workflows: [CIWorkflow] = []
    /// Icons by app ID (`CIProduct.appID`), and when Apple was last asked for them.
    var appIcons: [String: CIAppIcon] = [:]
    var appIconsCheckedAt: Date?
    /// The Xcode versions Xcode Cloud offers, and when Apple was last asked for them.
    var xcodeVersions: [CIXcodeVersion] = []
    var xcodeVersionsCheckedAt: Date?
    var lastSuccessfulSync: Date?

    static let empty = BuildSnapshot()

    init(
        products: [CIProduct] = [],
        runs: [CIBuildRun] = [],
        actionsByRunID: [String: [CIBuildAction]] = [:],
        testDevicesByActionID: [String: [CITestDeviceRun]] = [:],
        testResultAttempts: [String: Int] = [:],
        workflows: [CIWorkflow] = [],
        appIcons: [String: CIAppIcon] = [:],
        appIconsCheckedAt: Date? = nil,
        xcodeVersions: [CIXcodeVersion] = [],
        xcodeVersionsCheckedAt: Date? = nil,
        lastSuccessfulSync: Date? = nil
    ) {
        self.products = products
        self.runs = runs
        self.actionsByRunID = actionsByRunID
        self.testDevicesByActionID = testDevicesByActionID
        self.testResultAttempts = testResultAttempts
        self.workflows = workflows
        self.xcodeVersions = xcodeVersions
        self.xcodeVersionsCheckedAt = xcodeVersionsCheckedAt
        self.appIcons = appIcons
        self.appIconsCheckedAt = appIconsCheckedAt
        self.lastSuccessfulSync = lastSuccessfulSync
    }

    // Caches written before a field existed still load: the missing data is fetched on the next sync.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        products = try container.decodeIfPresent([CIProduct].self, forKey: .products) ?? []
        runs = try container.decodeIfPresent([CIBuildRun].self, forKey: .runs) ?? []
        actionsByRunID = try container.decodeIfPresent([String: [CIBuildAction]].self, forKey: .actionsByRunID) ?? [:]
        testDevicesByActionID = try container.decodeIfPresent([String: [CITestDeviceRun]].self, forKey: .testDevicesByActionID) ?? [:]
        testResultAttempts = try container.decodeIfPresent([String: Int].self, forKey: .testResultAttempts) ?? [:]
        workflows = try container.decodeIfPresent([CIWorkflow].self, forKey: .workflows) ?? []
        appIcons = try container.decodeIfPresent([String: CIAppIcon].self, forKey: .appIcons) ?? [:]
        appIconsCheckedAt = try container.decodeIfPresent(Date.self, forKey: .appIconsCheckedAt)
        xcodeVersions = try container.decodeIfPresent([CIXcodeVersion].self, forKey: .xcodeVersions) ?? []
        xcodeVersionsCheckedAt = try container.decodeIfPresent(Date.self, forKey: .xcodeVersionsCheckedAt)
        lastSuccessfulSync = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSync)
    }

    /// Something was read at least once, from Apple or from the cache: there is something to show, be it an empty list.
    var hasContent: Bool {
        lastSuccessfulSync != nil || !products.isEmpty || !runs.isEmpty
    }

    var hasActiveBuilds: Bool {
        runs.contains { $0.executionProgress != .complete }
    }

    func runs(forProductID productID: String) -> [CIBuildRun] {
        runs.filter { $0.productID == productID }
    }

    static let maximumTestResultAttempts = 3

    /// A completed test action whose per-device results are still to be fetched, and have not been given up on.
    func needsTestResults(_ action: CIBuildAction) -> Bool {
        action.actionType == .test && action.executionProgress == .complete
            && testDevicesByActionID[action.id] == nil
            && testResultAttempts[action.id, default: 0] < Self.maximumTestResultAttempts
    }

    func product(id: String) -> CIProduct? {
        products.first { $0.id == id }
    }

    func icon(of product: CIProduct?) -> CIAppIcon? {
        product?.appID.flatMap { appIcons[$0] }
    }

    /// Store names by product name, for what is keyed by the product: usage figures and colours.
    var displayNames: [String: String] {
        Dictionary(products.map { ($0.name, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    func workflow(id: String?) -> CIWorkflow? {
        id.flatMap { id in workflows.first { $0.id == id } }
    }
}

/// The cache lives in the app group container, where the `cumulus` command reads it.
nonisolated struct BuildCacheStore: Sendable {
    var fileURL: URL = AccountPaths.first.buildCache

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
