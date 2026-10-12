import SwiftUI

/// The Trends section of a workflow sheet: three figures over the newest finished builds, and a bar per build.
struct WorkflowTrendsSection: View {
    let trends: WorkflowTrends
    /// Opens a build's sheet.
    let openBuild: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trends")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if trends.sampleSize > 0 {
                    Text("Last \(trends.sampleSize) finished builds", comment: "How many builds the trends of a workflow are computed over")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if trends.sampleSize == 0 {
                Text("No finished build in the last 30 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    metric(
                        String(localized: "Median duration"),
                        value: trends.medianDuration.map { UsageFormat.minutes($0 / 60) },
                        drift: trends.durationDrift, lowerIsBetter: true
                    )
                    metric(
                        String(localized: "Queue wait", comment: "Median time a build waited for a machine before it started"),
                        value: trends.medianQueueWait.map { BuildRowData.clock($0) },
                        drift: trends.queueDrift, lowerIsBetter: true
                    )
                    metric(
                        String(localized: "Success rate"),
                        value: trends.successRate.map { UsageFormat.percent($0) },
                        drift: trends.successDrift, lowerIsBetter: false
                    )
                }
                if trends.bars.count > 1 {
                    chart
                    Text("Duration of each build, oldest first. Failed builds are in red. Click a bar to open the build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private func metric(_ title: String, value: String?, drift: WorkflowTrends.Drift?, lowerIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–").font(.title3.weight(.semibold).monospacedDigit())
            Text(Self.driftText(drift, sampleSize: trends.sampleSize))
                .font(.caption)
                .foregroundStyle(Self.driftTint(drift, lowerIsBetter: lowerIsBetter))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let longest = trends.bars.map(\.seconds).max() ?? 1
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(trends.bars) { bar in
                Button {
                    openBuild(bar.id)
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.succeeded ? AnyShapeStyle(.secondary.opacity(0.45)) : AnyShapeStyle(BuildStatus.failed.tint))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(4, 70 * bar.seconds / max(longest, 1)))
                }
                .buttonStyle(.plain)
                .help(Self.barLabel(bar))
                .accessibilityLabel(Self.barLabel(bar))
            }
        }
        .frame(height: 70, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Duration of each build"))
    }

    /// “#394 · 12 min · Succeeded”
    static func barLabel(_ bar: WorkflowTrends.Bar) -> String {
        let number = bar.number.map { "#\($0)" } ?? "#?"
        return UsageFormat.dotted([number, UsageFormat.minutes(bar.seconds / 60), bar.succeeded ? BuildStatus.succeeded.label : BuildStatus.failed.label])
    }

    static func driftText(_ drift: WorkflowTrends.Drift?, sampleSize: Int) -> String {
        guard let drift else {
            return sampleSize < WorkflowTrends.driftMinimum ? String(localized: "Not enough builds to compare yet") : ""
        }
        switch drift {
        case .stable:
            return String(localized: "Stable", comment: "The newest builds of a workflow do not differ from the ones before")
        case .change(let fraction):
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
            let count = min(WorkflowTrends.recentCount, sampleSize / 2)
            return String(localized: "\(percent) over the newest \(count)", comment: "How the newest builds drift from the ones before, e.g. “+18 % over the newest 10”")
        }
    }

    static func driftTint(_ drift: WorkflowTrends.Drift?, lowerIsBetter: Bool) -> Color {
        guard case .change(let fraction) = drift else { return .secondary }
        let worse = lowerIsBetter ? fraction > 0 : fraction < 0
        return worse ? BuildStatus.errored.tint : BuildStatus.succeeded.tint
    }
}
