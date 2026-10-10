import Foundation
import Observation

/// A product's workflows with their configuration, as last read from Apple.
nonisolated struct WorkflowDetailsFile: Codable, Sendable, Equatable {
    var fetchedAt: Date
    var workflows: [CIWorkflow]
}

nonisolated struct WorkflowDetailsCache: Sendable {
    var directory: URL = .applicationSupportDirectory.appending(path: "WorkflowDetails")

    @concurrent func load(productID: String) async -> WorkflowDetailsFile? {
        guard Self.isSafe(productID), let data = try? Data(contentsOf: directory.appending(path: "\(productID).json")) else { return nil }
        return try? JSONDecoder().decode(WorkflowDetailsFile.self, from: data)
    }

    @concurrent func save(_ file: WorkflowDetailsFile, productID: String) async {
        guard Self.isSafe(productID) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: directory.appending(path: "\(productID).json"), options: [.atomic])
    }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// Reads the configuration of a product's workflows when a workflow is opened: the cached copy at once,
/// then Apple's when that copy is older than an hour. A workflow changes rarely, so the hourly budget is spared.
@Observable
final class WorkflowDetailStore {
    static let freshness: TimeInterval = 3600

    private(set) var workflowsByID: [String: CIWorkflow] = [:]
    private var refreshedProducts: Set<String> = []
    private let cache: WorkflowDetailsCache
    private let client: () async -> AppStoreConnectClient?
    private let now: () -> Date

    init(cache: WorkflowDetailsCache = WorkflowDetailsCache(), client: @escaping () async -> AppStoreConnectClient?, now: @escaping () -> Date = { Date() }) {
        self.cache = cache
        self.client = client
        self.now = now
    }

    func workflow(id: String) -> CIWorkflow? {
        workflowsByID[id]
    }

    func load(productID: String) async {
        var isFresh = false
        if let stored = await cache.load(productID: productID) {
            merge(stored.workflows)
            isFresh = now().timeIntervalSince(stored.fetchedAt) < Self.freshness
        }
        guard !isFresh, refreshedProducts.insert(productID).inserted else { return }
        guard let client = await client(), let fetched = try? await client.workflowDetails(productID: productID) else {
            refreshedProducts.remove(productID)
            return
        }
        let tagged = fetched.map { workflow -> CIWorkflow in
            var workflow = workflow
            workflow.productID = productID
            return workflow
        }
        merge(tagged)
        await cache.save(WorkflowDetailsFile(fetchedAt: now(), workflows: tagged), productID: productID)
    }

    private func merge(_ workflows: [CIWorkflow]) {
        for workflow in workflows {
            workflowsByID[workflow.id] = workflow
        }
    }
}
