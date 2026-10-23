import SwiftUI
import UniformTypeIdentifiers

/// The details of the cycle, folded under the Overview's figure: the gauge of the menu, then the minutes by app and by workflow.
struct OverviewView: View {
    let summary: UsageSummary?
    let palette: AppPalette
    let usage: UsageStore
    let openSettings: () -> Void
    let openUsagePage: () -> Void
    /// An export picked by hand: it is read once and goes to the account whose apps it lists.
    let importExport: (URL) async -> Void
    /// Store names and loaded icons by product name.
    var displayNames: [String: String] = [:]
    var artwork: [String: AppArtwork] = [:]
    /// Where a workflow's minutes went, worked out from what the app already holds; nil when it cannot be told.
    var breakdown: (OverviewModel.WorkflowRow) -> WorkflowCostBreakdown? = { _ in nil }
    /// The scheduled workflows and when they next start; nil or empty leaves the section out.
    var forecast: ScheduleForecast?
    var openWorkflow: (String) -> Void = { _ in }

    @State private var isImporting = false
    @State private var expandedWorkflow: String?
    @Environment(ProAccess.self) private var access: ProAccess?

    var body: some View {
        let model = summary.map { OverviewModel(summary: $0, palette: palette, displayNames: displayNames) }
        let isMeasuring = summary?.measurement.isMeasuring ?? false
        return DetailColumnsBlock { columns in
            if let summary, let model {
                CycleRingGroup(summary: summary, model: model, artwork: artwork)
                details(model, columns: columns, isMeasuring: isMeasuring)
            } else {
                noPlan
            }
            if let forecast, !forecast.entries.isEmpty {
                Group {
                    if access.allows(.upcomingBuilds) {
                        upcoming(forecast)
                    } else {
                        ProLockedCard(feature: .upcomingBuilds)
                    }
                }
                .detailPlacement(.side)
            }
            // With a column for short facts, the most expensive build and the exports are cards of their own there.
            if columns == .two {
                if let costliest = isMeasuring ? BuildCost.placeholder : model?.costliestBuild {
                    section("Most expensive build") { costliestLine(costliest, showsTitle: false) }
                        .skeleton(isMeasuring, label: "Measuring usage…")
                        .detailPlacement(.side)
                }
                importCard
                    .detailPlacement(.side)
            } else {
                importLine
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await importExport(url) }
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
    private func details(_ model: OverviewModel, columns: DetailColumns, isMeasuring: Bool) -> some View {
        // While the builds are measured their figures are not known: the section stands as a skeleton of itself, with none.
        if isMeasuring || !model.workflows.isEmpty {
            section("Cost by workflow") {
                WorkflowBar(segments: isMeasuring ? OverviewModel.WorkflowSegment.placeholders : model.workflowBar)
                ForEach((isMeasuring ? OverviewModel.WorkflowRow.placeholders : model.workflows).prefix(OverviewModel.visibleWorkflows)) { workflow in
                    let isExpanded = expandedWorkflow == workflow.id
                    Button {
                        expandedWorkflow = isExpanded ? nil : workflow.id
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                            SwatchSquare(color: workflow.swatch.color.opacity(workflow.shade))
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
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text("Shows where this workflow’s minutes went"))
                    .accessibilityAddTraits(isExpanded ? .isSelected : [])
                    if isExpanded, !access.allows(.workflowCostBreakdown) {
                        ProLockedCard(feature: .workflowCostBreakdown)
                    } else if isExpanded, let breakdown = breakdown(workflow) {
                        WorkflowBreakdownView(breakdown: breakdown)
                    }
                }
                if columns == .one, let costliest = isMeasuring ? BuildCost.placeholder : model.costliestBuild {
                    Divider()
                    costliestLine(costliest, showsTitle: true)
                }
            }
            .skeleton(isMeasuring, label: "Measuring usage…")
        }
    }

    private func costliestLine(_ costliest: BuildCost, showsTitle: Bool) -> some View {
        let build = Text(UsageFormat.dotted([costliest.product, "#\(costliest.buildNumber)", costliest.workflow].compactMap(\.self))).fontWeight(.semibold)
        let minutes = Text((costliest.isEstimated ? "~" : "") + UsageFormat.minutes(costliest.minutes)).font(.callout.monospacedDigit())
        let title = Text("Most expensive build").foregroundStyle(.secondary).unredacted()
        // The title before the build on one line; above it in a column too narrow for both.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                if showsTitle { title.lineLimit(1).fixedSize() }
                build.lineLimit(1).fixedSize()
                Spacer()
                minutes.lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsTitle { title }
                HStack(alignment: .firstTextBaseline) {
                    build.lineLimit(2)
                    Spacer()
                    minutes.lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func upcoming(_ forecast: ScheduleForecast) -> some View {
        section("Upcoming") {
            ForEach(forecast.entries) { entry in
                Button {
                    openWorkflow(entry.workflowID)
                } label: {
                    let facts = UsageFormat.dotted([entry.productName, entry.source, Self.frequencyText(entry.frequency)].compactMap(\.self))
                    let when = Self.whenText(entry.nextRun, now: forecast.now)
                    let cost = entry.minutesPerRun.map { String(localized: "~\(UsageFormat.minutes($0)) estimated", comment: "What one scheduled build is expected to cost, from past builds") }
                        ?? String(localized: "No build yet to estimate from")
                    // On one line when it fits; in the side column, what and when first, the rest under them.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.workflowName).fontWeight(.semibold).lineLimit(1).fixedSize()
                            Text(facts).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            Spacer(minLength: 8)
                            Text(when).font(.callout.monospacedDigit()).lineLimit(1).fixedSize()
                            Text(cost).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.workflowName).fontWeight(.semibold).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(when).font(.callout.monospacedDigit()).lineLimit(1).fixedSize()
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(facts).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(cost).lineLimit(1).fixedSize()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
            if let total = forecast.minutesUntilReset {
                Text(Self.totalText(total, hasUnestimatedRuns: forecast.hasUnestimatedRuns))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func frequencyText(_ frequency: CIScheduleFrequency) -> String {
        switch frequency {
        case .hourly: String(localized: "every hour", comment: "Frequency of a scheduled workflow, in a caption")
        case .daily: String(localized: "every day", comment: "Frequency of a scheduled workflow, in a caption")
        case .weekly: String(localized: "every week", comment: "Frequency of a scheduled workflow, in a caption")
        }
    }

    /// “today 14:00”, “tomorrow 02:00”, “Monday 06:00”, then the date.
    nonisolated static func whenText(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "today \(time)", comment: "When a scheduled build next starts; the argument is a time")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow \(time)", comment: "When a scheduled build next starts; the argument is a time")
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(style.weekday(.wide).hour().minute())
        }
        return UsageFormat.moment(date, locale: locale)
    }

    static func totalText(_ minutes: Double, hasUnestimatedRuns: Bool) -> String {
        let total = String(localized: "By the end of the cycle, the scheduled builds will cost about \(UsageFormat.minutes(minutes)), based on their past durations.")
        guard hasUnestimatedRuns else { return total }
        return total + " " + String(localized: "Workflows without a build this cycle are not counted.")
    }

    /// The usage exports, at the foot: when the last one came in, and the two ways to bring one.
    private var importLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            importMessage
            HStack(spacing: 14) {
                importStatus
                importActions
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// The same, as a card of the side column.
    private var importCard: some View {
        section("Usage export") {
            VStack(alignment: .leading, spacing: 6) {
                importMessage
                importStatus
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { importActions }
                    VStack(alignment: .leading, spacing: 6) { importActions }
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var importMessage: some View {
        if let message = usage.lastImportMessage {
            Label(message, systemImage: usage.lastImportFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(usage.lastImportFailed ? BuildStatus.failed.tint : BuildStatus.succeeded.tint)
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if let lastImport = usage.ledger.lastImport {
            Text("Last export imported \(lastImport.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
        } else {
            Text("No usage export imported yet.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var importActions: some View {
        Button("Import an Export…") { isImporting = true }.buttonStyle(.link)
        Button("Update from App Store Connect", action: openUsagePage).buttonStyle(.link)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }
}
