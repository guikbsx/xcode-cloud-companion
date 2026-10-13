import SwiftUI

/// What a window asks about Cumulus Pro: whether a function is open, and the way to the purchase sheet. One per
/// window, handed down through the environment. A view that finds none (a test, a preview) treats everything as open.
@Observable
final class ProAccess {
    let store: ProStore
    private let purchase: (ProFeature) -> Void

    init(store: ProStore, purchase: @escaping (ProFeature) -> Void) {
        self.store = store
        self.purchase = purchase
    }

    func allows(_ feature: ProFeature) -> Bool {
        store.allows(feature)
    }

    /// Opens the purchase sheet with the benefit of `feature` first.
    func showPurchase(for feature: ProFeature) {
        purchase(feature)
    }
}

extension Optional where Wrapped == ProAccess {
    func allows(_ feature: ProFeature) -> Bool {
        self?.allows(feature) ?? true
    }
}

/// What a locked function says of itself on its card: its name, and in one sentence what it shows.
nonisolated enum ProFeatureText {
    /// What a store answers when asked for a locked function. The window never gets that far: it shows the purchase sheet.
    static var required: String { String(localized: "This needs Cumulus Pro.") }

    static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .regressions: String(localized: "What Broke")
        case .failureInsight: String(localized: "In Brief")
        case .testHealth: String(localized: "Flaky and Slow Tests")
        case .workflowTrends: String(localized: "Trends")
        case .workflowCostBreakdown: String(localized: "Why This Workflow Costs")
        case .upcomingBuilds: String(localized: "Upcoming Builds")
        case .appOverview: String(localized: "App Overview")
        case .olderBuilds: String(localized: "Older Builds")
        case .openInXcode: String(localized: "Open in Xcode")
        case .pauseWorkflow: String(localized: "Pause a Workflow")
        case .editWorkflow: String(localized: "Edit a Workflow")
        case .earlyUsageAlerts: String(localized: "Early Plan Alerts")
        case .stuckBuildAlert: String(localized: "Stuck Build Alert")
        case .multipleAccounts: String(localized: "Several Accounts")
        case .commandLine: String(localized: "The cumulus Command")
        case .mcpServer: String(localized: "MCP Server")
        }
    }

    static func sentence(_ feature: ProFeature) -> String {
        switch feature {
        case .regressions: String(localized: "The tests this build broke and the new issues, compared with the last successful build.")
        case .failureInsight: String(localized: "A one-line summary of a failed build and its tests in groups, written on this Mac by Apple Intelligence.")
        case .testHealth: String(localized: "The test that fails then passes on the same commit, and the ones that cost the most minutes.")
        case .workflowTrends: String(localized: "Median duration, time in the queue and success rate over the last thirty builds.")
        case .workflowCostBreakdown: String(localized: "Where the minutes of this workflow go: build, tests per device, archive, retries.")
        case .upcomingBuilds: String(localized: "The scheduled builds still to run this cycle, and what they are likely to cost.")
        case .appOverview: String(localized: "One app at a glance: its workflows, its cycle, its last builds, its branches.")
        case .olderBuilds: String(localized: "The builds from before the last 35 days.")
        case .openInXcode: String(localized: "Open the failing file in Xcode, at the right line, from your local clone.")
        case .pauseWorkflow: String(localized: "Pause and resume a workflow without leaving Cumulus.")
        case .editWorkflow: String(localized: "Change a workflow's name, its clean build and its Xcode version.")
        case .earlyUsageAlerts: String(localized: "A warning at 75 % of the plan, and when the pace will not last until the reset.")
        case .stuckBuildAlert: String(localized: "A warning when an action runs far longer than it usually does.")
        case .multipleAccounts: String(localized: "Follow several App Store Connect teams, each with its own key.")
        case .commandLine: String(localized: "Every cumulus command, for your terminal and your agents.")
        case .mcpServer: String(localized: "The MCP server, for Claude Code, Codex, Xcode and Claude Desktop.")
        }
    }
}

/// Where a Pro function would be, without Pro: its name, what it shows, and the way to the purchase sheet. It never
/// takes more room than the function it stands for.
struct ProLockedCard: View {
    let feature: ProFeature
    @Environment(ProAccess.self) private var access: ProAccess?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                badge
                text
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    badge
                    text
                }
                button
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private var badge: some View {
        Image(systemName: "lock")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 34, height: 34)
            .background(.tint.opacity(0.14), in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ProFeatureText.title(feature))
                    .fontWeight(.semibold)
                Text("Cumulus Pro")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
            }
            Text(ProFeatureText.sentence(feature))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var button: some View {
        Button("Discover Pro") {
            access?.showPurchase(for: feature)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }
}
