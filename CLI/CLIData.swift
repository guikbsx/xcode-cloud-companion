import Foundation

/// What the app left in the shared folder, read once per command.
nonisolated struct CLIData: Sendable {
    var snapshot: BuildSnapshot
    var ledger: UsageLedger
    var plan: UsagePlan?
    /// Workflow configurations read when a workflow was opened in the app: richer than the snapshot's, when present.
    var workflowDetails: [CIWorkflow]

    /// The snapshot is required: without it the app never synced, and nothing can be answered.
    static func load(from directory: URL, includingUsage: Bool, includingWorkflowDetails: Bool = false) async throws(CLIFailure) -> CLIData {
        guard let snapshot = await BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json")).load() else {
            throw CLIFailure.noCache
        }
        var data = CLIData(snapshot: snapshot, ledger: UsageLedger(), plan: nil, workflowDetails: [])
        if includingUsage {
            data.ledger = await UsageLedgerStore(fileURL: directory.appending(path: "UsageLedger.json")).load() ?? UsageLedger()
            data.plan = await SharedPlanStore(fileURL: directory.appending(path: "UsagePlan.json")).load()
        }
        if includingWorkflowDetails {
            let cache = WorkflowDetailsCache(directory: directory.appending(path: "WorkflowDetails"))
            for product in snapshot.products {
                data.workflowDetails += await cache.load(productID: product.id)?.workflows ?? []
            }
        }
        return data
    }
}
