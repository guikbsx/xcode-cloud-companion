import Foundation

/// What the sidebar lists, worked out from a snapshot: products with their workflows, and the pinned workflows.
nonisolated struct SidebarContent: Equatable {
    struct Workflow: Identifiable, Equatable {
        let id: String
        let name: String
        let productID: String
        let productName: String
        let buildCount: Int
        /// As Apple last said; nil while the app does not know.
        var isEnabled: Bool? = nil
        var isLocked = false
        /// Builds with an Xcode older than the newest public one Xcode Cloud offers.
        var isOnOlderXcode = false

        var isPaused: Bool { isEnabled == false }
    }

    struct Product: Identifiable, Equatable {
        let id: String
        /// The name shown: the App Store name when the product is an app that has one.
        let name: String
        let buildCount: Int
        let lastStatus: BuildStatus?
        let swatch: AppSwatch
        let workflows: [Workflow]
    }

    var runningCount = 0
    var pinned: [Workflow] = []
    var products: [Product] = []

    init(snapshot: BuildSnapshot, pinnedIDs: [String], palette: AppPalette) {
        runningCount = snapshot.runs.filter { BuildStatus(run: $0) == .running }.count

        let runsByProduct = Dictionary(grouping: snapshot.runs, by: \.productID)
        let runsByWorkflow = Dictionary(grouping: snapshot.runs.filter { $0.workflowID != nil }, by: { $0.workflowID ?? "" })
        let productsByID = Dictionary(snapshot.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var workflowsByProduct: [String: [Workflow]] = [:]
        for workflow in snapshot.workflows {
            let runs = runsByWorkflow[workflow.id] ?? []
            guard let productID = workflow.productID ?? runs.first?.productID, let product = productsByID[productID] else { continue }
            workflowsByProduct[productID, default: []].append(
                Workflow(
                    id: workflow.id, name: workflow.name, productID: productID, productName: product.displayName, buildCount: runs.count,
                    isEnabled: workflow.isEnabled, isLocked: workflow.isLockedForEditing == true,
                    isOnOlderXcode: XcodeVersionCheck.warning(version: workflow.xcodeVersion, name: nil, among: snapshot.xcodeVersions) != nil
                )
            )
        }

        products = snapshot.products
            .map { product in
                let runs = runsByProduct[product.id] ?? []
                let latest = runs.max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
                return Product(
                    id: product.id,
                    name: product.displayName,
                    buildCount: runs.count,
                    lastStatus: latest.map(BuildStatus.init(run:)),
                    swatch: palette.swatch(for: product.name),
                    workflows: (workflowsByProduct[product.id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { lhs, rhs in
                let (left, right) = (latestCreation(runsByProduct[lhs.id]), latestCreation(runsByProduct[rhs.id]))
                return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left > right
            }

        let all = Dictionary(products.flatMap(\.workflows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pinned = pinnedIDs.compactMap { all[$0] }
    }

    private func latestCreation(_ runs: [CIBuildRun]?) -> Date {
        runs?.compactMap(\.createdDate).max() ?? .distantPast
    }
}
