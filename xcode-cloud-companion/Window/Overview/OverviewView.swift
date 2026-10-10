import SwiftUI
import UniformTypeIdentifiers

/// The cycle at a glance: the gauge of the menu, then the minutes by app and by workflow.
struct OverviewView: View {
    let summary: UsageSummary?
    let palette: AppPalette
    let usage: UsageStore
    let openSettings: () -> Void
    let openUsagePage: () -> Void

    @State private var isImporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Overview").font(.system(size: 30, weight: .bold, design: .rounded))
                if let summary {
                    UsageGaugeView(summary: summary, palette: palette).cumulusGroup()
                    if !summary.measurement.isMeasuring {
                        details(OverviewModel(summary: summary, palette: palette))
                    }
                } else {
                    noPlan
                }
                importGroup
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await usage.importFile(at: url) }
            }
        }
    }

    private var noPlan: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Set your plan’s reset date to see the cycle.", systemImage: "calendar.badge.clock")
                .font(.headline)
            Text("Apple publishes no usage figure through its API: the gauge needs your plan and the day it resets.")
                .foregroundStyle(.secondary)
            Button("Set Your Plan…", action: openSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    @ViewBuilder
    private func details(_ model: OverviewModel) -> some View {
        if !model.apps.isEmpty {
            section("Minutes by app") {
                ForEach(model.apps) { app in
                    HStack(spacing: 10) {
                        AppIconView(name: app.name, swatch: app.swatch, size: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(app.name).fontWeight(.semibold)
                                Spacer()
                                Text(Self.minutesText(app)).font(.callout.monospacedDigit())
                            }
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 6)
                                .overlay(alignment: .leading) {
                                    GeometryReader { proxy in
                                        Capsule().fill(app.swatch.color).frame(width: max(4, proxy.size.width * app.share))
                                    }
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.hasEstimates {
                    Text("Figures with a ~ are estimates computed from the builds’ durations, not Apple’s billing. Import an export for exact minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !model.workflows.isEmpty {
            section("Cost by workflow") {
                ForEach(model.workflows.prefix(8)) { workflow in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.workflow).fontWeight(.semibold)
                            Text(UsageFormat.dotted([workflow.product, String(localized: "\(workflow.buildCount) builds")]))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text((workflow.isEstimated ? "~" : "") + UsageFormat.minutes(workflow.totalMinutes)).font(.callout.monospacedDigit())
                            Text(String(localized: "\(UsageFormat.minutes(workflow.averageMinutes)) per build"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if let costliest = model.costliestBuild {
            section("Most expensive build") {
                HStack {
                    Text(UsageFormat.dotted([costliest.product, "#\(costliest.buildNumber)", costliest.workflow].compactMap(\.self))).fontWeight(.semibold)
                    Spacer()
                    Text((costliest.isEstimated ? "~" : "") + UsageFormat.minutes(costliest.minutes)).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private var importGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lastImport = usage.ledger.lastImport {
                LabeledContent("Last export imported", value: lastImport.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("No usage export imported yet.").foregroundStyle(.secondary)
            }
            if let message = usage.lastImportMessage {
                Label(message, systemImage: usage.lastImportFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(usage.lastImportFailed ? BuildStatus.failed.tint : BuildStatus.succeeded.tint)
            }
            HStack {
                Button("Import an Export…") { isImporting = true }
                Button("Update from App Store Connect", action: openUsagePage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private static func minutesText(_ app: OverviewModel.AppRow) -> String {
        if app.estimatedMinutes > 0, app.billedMinutes > 0 {
            return "\(UsageFormat.minutes(app.billedMinutes)) + ~\(UsageFormat.minutes(app.estimatedMinutes))"
        }
        return (app.estimatedMinutes > 0 ? "~" : "") + UsageFormat.minutes(app.totalMinutes)
    }
}
