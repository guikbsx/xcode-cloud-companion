import Foundation

/// What the Overview shows besides the gauge, from the same `UsageSummary` as the menu: no calculation of its own.
nonisolated struct OverviewModel: Equatable, Sendable {
    struct AppRow: Identifiable, Equatable, Sendable {
        /// The product name: the key of the colour, of the usage and of the icon.
        let name: String
        let displayName: String
        let swatch: AppSwatch
        let billedMinutes: Double
        let estimatedMinutes: Double
        /// Share of everything used in the cycle, 0...1.
        let share: Double

        var id: String { name }
        var totalMinutes: Double { billedMinutes + estimatedMinutes }

        /// “58 min”, “~3 min” for an estimate, “12 min + ~3 min” when Apple billed part of it.
        var minutesText: String {
            if estimatedMinutes > 0, billedMinutes > 0 {
                return "\(UsageFormat.minutes(billedMinutes)) + ~\(UsageFormat.minutes(estimatedMinutes))"
            }
            return (estimatedMinutes > 0 ? "~" : "") + UsageFormat.minutes(totalMinutes)
        }
    }

    /// An app's arc of the ring, as fractions of the whole turn; what is left of the turn is what is left of the plan.
    struct RingSegment: Identifiable, Equatable, Sendable {
        let id: String
        let swatch: AppSwatch
        let start: Double
        let end: Double
    }

    /// A slice of the bar above the workflows; `swatch` nil is the neutral slice of the workflows not listed.
    struct WorkflowSegment: Identifiable, Equatable, Sendable {
        let id: String
        let swatch: AppSwatch?
        let shade: Double
        /// Share of all the workflows' minutes, 0...1.
        let fraction: Double
    }

    struct WorkflowRow: Identifiable, Equatable, Sendable {
        /// The product name, the key of the usage; `product` is the name shown.
        let productKey: String
        let product: String
        let workflow: String
        let buildCount: Int
        let totalMinutes: Double
        let averageMinutes: Double
        let isEstimated: Bool
        /// Its app's colour, lighter for each further workflow of the same app.
        var swatch = AppSwatch.gray
        var shade = 1.0

        var id: String { "\(productKey)|\(workflow)" }
    }

    /// How many workflows the Overview lists; the others share one neutral slice of the bar.
    static let visibleWorkflows = 8
    /// The ring's circumference in points: a slice never gets thinner than the gauge's minimum.
    private static let ringLength = 340.0

    let apps: [AppRow]
    let ring: [RingSegment]
    let workflowBar: [WorkflowSegment]
    let workflows: [WorkflowRow]
    let costliestBuild: BuildCost?
    /// Some of the minutes shown are estimated rather than billed: the Overview says so.
    let hasEstimates: Bool

    /// `displayNames` gives the Store name of each product name; a product without one keeps its own.
    init(summary: UsageSummary, palette: AppPalette, displayNames: [String: String] = [:]) {
        let used = max(summary.usedMinutes, 0.0001)
        apps = summary.byApp.filter { $0.totalMinutes > 0 }.map {
            AppRow(
                name: $0.product, displayName: displayNames[$0.product] ?? $0.product, swatch: palette.swatch(for: $0.product), billedMinutes: $0.billedMinutes,
                estimatedMinutes: $0.estimatedMinutes, share: min($0.totalMinutes / used, 1)
            )
        }
        let widths = GaugeLayout.widths(minutes: apps.map(\.totalMinutes), quotaMinutes: summary.quotaMinutes, totalWidth: Self.ringLength)
        var cursor = 0.0
        ring = zip(apps, widths).map { app, width in
            let start = cursor
            cursor = min(1, cursor + width / Self.ringLength)
            return RingSegment(id: app.name, swatch: app.swatch, start: start, end: cursor)
        }

        var rank: [String: Int] = [:]
        workflows = summary.byWorkflow.filter { $0.totalMinutes > 0 }.map {
            let position = rank[$0.product, default: 0]
            rank[$0.product] = position + 1
            return WorkflowRow(
                productKey: $0.product, product: displayNames[$0.product] ?? $0.product, workflow: $0.workflow, buildCount: $0.buildCount, totalMinutes: $0.totalMinutes,
                averageMinutes: $0.averageMinutes, isEstimated: $0.estimatedMinutes > 0,
                swatch: palette.swatch(for: $0.product), shade: max(0.35, 1 - 0.22 * Double(position))
            )
        }
        let total = max(workflows.reduce(0) { $0 + $1.totalMinutes }, 0.0001)
        var bar = workflows.prefix(Self.visibleWorkflows).map {
            WorkflowSegment(id: $0.id, swatch: $0.swatch, shade: $0.shade, fraction: $0.totalMinutes / total)
        }
        let others = workflows.dropFirst(Self.visibleWorkflows).reduce(0) { $0 + $1.totalMinutes }
        if others > 0 {
            bar.append(WorkflowSegment(id: "others", swatch: nil, shade: 1, fraction: others / total))
        }
        workflowBar = bar
        costliestBuild = summary.costliestBuild.map { build in
            var build = build
            build.product = displayNames[build.product] ?? build.product
            return build
        }
        hasEstimates = summary.estimatedMinutes > 0
    }
}
