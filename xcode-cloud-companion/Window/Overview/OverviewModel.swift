import Foundation

/// What the Overview shows besides the gauge, from the same `UsageSummary` as the menu: no calculation of its own.
nonisolated struct OverviewModel: Equatable, Sendable {
    struct AppRow: Identifiable, Equatable, Sendable {
        let name: String
        let swatch: AppSwatch
        let billedMinutes: Double
        let estimatedMinutes: Double
        /// Share of everything used in the cycle, 0...1.
        let share: Double

        var id: String { name }
        var totalMinutes: Double { billedMinutes + estimatedMinutes }
    }

    struct WorkflowRow: Identifiable, Equatable, Sendable {
        let product: String
        let workflow: String
        let buildCount: Int
        let totalMinutes: Double
        let averageMinutes: Double
        let isEstimated: Bool

        var id: String { "\(product)|\(workflow)" }
    }

    let apps: [AppRow]
    let workflows: [WorkflowRow]
    let costliestBuild: BuildCost?
    /// Some of the minutes shown are estimated rather than billed: the Overview says so.
    let hasEstimates: Bool

    init(summary: UsageSummary, palette: AppPalette) {
        let used = max(summary.usedMinutes, 0.0001)
        apps = summary.byApp.filter { $0.totalMinutes > 0 }.map {
            AppRow(
                name: $0.product, swatch: palette.swatch(for: $0.product), billedMinutes: $0.billedMinutes,
                estimatedMinutes: $0.estimatedMinutes, share: min($0.totalMinutes / used, 1)
            )
        }
        workflows = summary.byWorkflow.filter { $0.totalMinutes > 0 }.map {
            WorkflowRow(
                product: $0.product, workflow: $0.workflow, buildCount: $0.buildCount, totalMinutes: $0.totalMinutes,
                averageMinutes: $0.averageMinutes, isEstimated: $0.estimatedMinutes > 0
            )
        }
        costliestBuild = summary.costliestBuild
        hasEstimates = summary.estimatedMinutes > 0
    }
}
