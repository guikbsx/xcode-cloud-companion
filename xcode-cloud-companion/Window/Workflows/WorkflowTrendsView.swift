import SwiftUI

/// The Trends section of a workflow sheet: three figures over the newest finished builds, and a bar per build.
struct WorkflowTrendsSection: View {
    let trends: WorkflowTrends
    /// Set when the workflow's successful builds got slower from one build on; nil leaves the card out.
    var slowdown: WorkflowSlowdownModel?
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
                if let slowdown {
                    slowdownHeader(slowdown)
                }
                if trends.bars.count > 1 {
                    chart(slowdown: slowdown)
                    Text("Duration of each build, oldest first. Failed builds are in red. Click a bar to open the build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let slowdown {
                    slowdownDetails(slowdown)
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

    private func slowdownHeader(_ slowdown: WorkflowSlowdownModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WorkflowSlowdownText.title(since: slowdown.since)).fontWeight(.semibold)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(WorkflowSlowdownText.headline(slowdown.slowdown))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                CapsuleTag(text: WorkflowSlowdownText.increase(slowdown.slowdown), systemImage: "arrow.up", tint: BuildStatus.errored.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func slowdownDetails(_ slowdown: WorkflowSlowdownModel) -> some View {
        let changes = Array(slowdown.slowdown.actions.prefix(Self.actionRows))
        if !changes.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { offset, change in
                    let isCause = offset == 0 && WorkflowSlowdownText.delta(change) != nil
                    HStack(spacing: 10) {
                        Text(change.name).fontWeight(isCause ? .bold : .regular).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(WorkflowSlowdownText.change(change))
                            .fontWeight(isCause ? .bold : .regular)
                            .foregroundStyle(isCause ? Color.primary : Color.secondary)
                            .monospacedDigit()
                        Group {
                            if isCause, let delta = WorkflowSlowdownText.delta(change) {
                                CapsuleTag(text: delta, tint: BuildStatus.errored.tint)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Divider() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        HStack(spacing: 8) {
            Button {
                openBuild(slowdown.run.id)
            } label: {
                if let number = slowdown.buildNumber {
                    Text("Open \(number)", comment: "Button that opens the build a slowdown starts at. The placeholder is its number, such as “#398”.")
                } else {
                    Text("Open the build")
                }
            }
            .buttonStyle(.borderedProminent)
            if let url = slowdown.commitURL {
                Button("View commit") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        if let extra = slowdown.extra {
            Text(WorkflowSlowdownText.extraLine(extra))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Rows of the action table: the cause leads, a few more show that the others stayed where they were.
    private static let actionRows = 4

    /// “#398 · a41c7e2 · “Add snapshot tests””
    private func markerLabel(_ slowdown: WorkflowSlowdownModel) -> String {
        var parts = [slowdown.buildNumber, slowdown.shortSHA].compactMap(\.self)
        if let title = slowdown.commitTitle {
            parts.append(String(localized: "“\(title)”", comment: "A commit's first line, in quotation marks"))
        }
        return UsageFormat.dotted(parts)
    }

    private func chart(slowdown: WorkflowSlowdownModel?) -> some View {
        let marker = slowdown.flatMap { slowdown in trends.bars.firstIndex { $0.id == slowdown.run.id } }
        return bars
            .padding(.top, marker == nil ? 0 : 22)
            .overlay {
                if let slowdown, let marker {
                    markerOverlay(index: marker, label: markerLabel(slowdown))
                        .accessibilityHidden(true)
                }
            }
    }

    /// A dashed line between the last bar of the old level and the build that starts the new one, with that build named
    /// above it on the side that has room.
    private func markerOverlay(index: Int, label: String) -> some View {
        GeometryReader { geometry in
            let step = (geometry.size.width + Self.barSpacing) / CGFloat(trends.bars.count)
            let x = max(0, CGFloat(index) * step - Self.barSpacing / 2)
            let onLeft = x > geometry.size.width / 2
            let room = max(0, (onLeft ? x : geometry.size.width - x) - 8)
            Path { path in
                path.move(to: CGPoint(x: x, y: 4))
                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
            }
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: room, alignment: onLeft ? .trailing : .leading)
                .offset(x: onLeft ? x - 6 - room : x + 6)
        }
    }

    private static let barSpacing: CGFloat = 3

    private var bars: some View {
        let longest = trends.bars.map(\.seconds).max() ?? 1
        return HStack(alignment: .bottom, spacing: Self.barSpacing) {
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
