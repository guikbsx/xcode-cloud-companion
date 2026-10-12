import SwiftUI

/// The app's newest finished builds, a bar each: how long it ran, red when it failed. A click opens the build.
struct AppBuildsChart: View {
    let bars: [WorkflowTrends.Bar]
    let medianQueueWait: TimeInterval?
    let swatch: AppSwatch
    let openBuild: (String) -> Void

    private static let height: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                AppOverviewHeading(title: Text("Last \(bars.count) finished builds", comment: "How many builds the trends of a workflow are computed over"))
                Spacer(minLength: 8)
                if let medianQueueWait {
                    Text("Median queue wait: \(BuildRowData.clock(medianQueueWait))", comment: "Beside the chart of an app's last builds: how long a build waits for a machine, as a clock (0:12)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            chart
            Text("Duration of each build, oldest first. Failed builds are in red. Click a bar to open the build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private var chart: some View {
        let longest = max(bars.map(\.seconds).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars) { bar in
                Button {
                    openBuild(bar.id)
                } label: {
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(bar.succeeded ? AnyShapeStyle(swatch.color.opacity(0.55)) : AnyShapeStyle(BuildStatus.failed.tint))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(4, Self.height * bar.seconds / longest))
                        .frame(height: Self.height, alignment: .bottom)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(WorkflowTrendsSection.barLabel(bar))
                .accessibilityLabel(WorkflowTrendsSection.barLabel(bar))
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Duration of each build"))
    }
}

/// The app's newest branches and pull requests, each with how its last build went. A click lists the reference's builds.
struct AppReferencesGroup: View {
    let references: [ReferenceRow]
    let now: Date
    let openReference: (AppReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppOverviewHeading(title: Text("Branches and pull requests"))
                .padding(.bottom, 8)
            ForEach(Array(references.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                Button {
                    openReference(row.reference)
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(status: row.status)
                        Image(systemName: row.key.isPullRequest ? "arrow.triangle.pull" : "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(row.title).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(UsageFormat.dotted([row.lastRun.number.map { "#\($0)" }, row.age(now: now)].compactMap(\.self)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(UsageFormat.dotted([row.title, row.status.label, row.lastRun.number.map { "#\($0)" }].compactMap(\.self))))
                .accessibilityHint(Text("Lists this reference’s builds"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }
}

/// What deserves a look: an Xcode left behind, the build that cost the most, and how much of the figures is estimated.
struct AppNotesGroup: View {
    let model: AppOverviewModel
    let openBuild: (String) -> Void

    /// Nothing to say: the group is left out.
    static func isEmpty(_ model: AppOverviewModel) -> Bool {
        !model.workflows.contains { $0.xcodeWarning != nil } && model.costliestBuild == nil && model.cycle?.hasEstimates != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppOverviewHeading(title: Text("Worth noting", comment: "Heading of a short list of remarks about an app: an outdated Xcode, its most expensive build"))
            ForEach(model.workflows.filter { $0.xcodeWarning != nil }) { row in
                if let warning = row.xcodeWarning {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(BuildStatus.errored.tint)
                            .accessibilityHidden(true)
                        Text("\(Text(warning.current).fontWeight(.semibold)) on \(row.name): \(warning.latest) is available.",
                             comment: "An app's workflow builds with an older Xcode: its version, the workflow's name, then the newest version")
                    }
                }
            }
            if let costliest = model.costliestBuild {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Most expensive build").foregroundStyle(.secondary)
                    if let runID = model.costliestRunID {
                        Button {
                            openBuild(runID)
                        } label: {
                            Text(verbatim: "#\(costliest.buildNumber)")
                        }
                        .buttonStyle(.link)
                    } else {
                        Text(verbatim: "#\(costliest.buildNumber)").fontWeight(.semibold)
                    }
                    Spacer(minLength: 8)
                    Text(AppOverviewText.minutes(costliest.minutes, isEstimated: costliest.isEstimated)).font(.callout.monospacedDigit())
                }
            }
            if let cycle = model.cycle, cycle.hasEstimates, !cycle.isMeasuring {
                Text(AppOverviewText.estimateNote(lastImport: cycle.lastImport))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }
}

/// A group's small heading, as in the Overview.
struct AppOverviewHeading: View {
    let title: Text

    var body: some View {
        title
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The last build the app handed to TestFlight, beside its name.
struct TestFlightPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.primary.opacity(0.07), in: .capsule)
            .fixedSize()
    }
}
