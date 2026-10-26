import SwiftUI

/// Under a workflow of the Overview: where its minutes of the cycle went, and what the figures say. No advice, only what was measured.
struct WorkflowBreakdownView: View {
    let breakdown: WorkflowCostBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sourceNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let formulaNote {
                Text(formulaNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if breakdown.unsplitTestActions > 0 {
                Label(
                    "Test actions without per-device results from Apple: \(breakdown.unsplitTestActions). Their time is counted whole, so the split by destination is incomplete.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(BuildStatus.errored.tint)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(breakdown.items) { item in
                    HStack(spacing: 10) {
                        Text(item.kind.title).frame(maxWidth: .infinity, alignment: .leading)
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 120, height: 5)
                            .overlay(alignment: .leading) {
                                Capsule().fill(CumulusStyle.accent).frame(width: max(3, 120 * item.share))
                            }
                            .accessibilityHidden(true)
                        Text(UsageFormat.percent(item.share)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        Text("~" + UsageFormat.minutes(item.minutes)).font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(Array(breakdown.findings.enumerated()), id: \.offset) { _, finding in
                Label(finding.text, systemImage: "lightbulb")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    /// Says which way Apple's latest bills for the workflow point, when it is not the usual one.
    private var formulaNote: String? {
        switch breakdown.formula {
        case .machine:
            nil
        case .deviceWallClock:
            String(localized: "Apple’s latest bills for this workflow follow how long its test action runs, on each device: each destination is counted for that whole time, with no separate preparation.")
        case .actionWallClock:
            String(localized: "Apple’s latest bills for this workflow follow how long its actions run: each action is counted for its whole duration.")
        }
    }

    /// Says what the total is (Apple's or an estimate) and that the split is the app's own.
    private var sourceNote: String {
        let total = UsageFormat.minutes(breakdown.totalMinutes)
        let builds = String(localized: "\(breakdown.buildCount) builds")
        if breakdown.isEstimated {
            return String(
                localized: "~\(total) over \(builds). Builds estimated from their actions, not yet in a usage export: \(breakdown.estimatedBuildCount). The split below follows the same model."
            )
        }
        return String(
            localized: "\(total) over \(builds): exact minutes, from Apple’s usage export. Apple gives one figure per build, so the split below is modelled from each build’s actions."
        )
    }
}
