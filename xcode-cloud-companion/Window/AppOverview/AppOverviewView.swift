import SwiftUI

/// One app at a glance, in the right column when the app is picked in the sidebar: who it is, its share of the cycle,
/// then its workflows side by side.
struct AppOverviewView: View {
    let model: AppOverviewModel
    let swatch: AppSwatch
    var artwork: AppArtwork?
    let now: Date
    /// “TestFlight: build 386 · 4d”, once the build handed to testers is known.
    var testFlight: String?
    /// The TestFlight build is on its way: the pill stands as a skeleton of itself.
    var isTestFlightPending = false
    /// The app's TestFlight card; nil leaves it out.
    var testFlightCard: TestFlightCard.Content?
    var openSettings: () -> Void = {}
    var openWorkflow: (String) -> Void = { _ in }
    var openBuild: (String) -> Void = { _ in }
    var openReference: (AppReference) -> Void = { _ in }
    @Environment(ProAccess.self) private var access: ProAccess?

    var body: some View {
        // Halves, not a main column and a side one: the table of workflows needs the whole width to stay a table.
        DetailScroll(spacing: 14, sideWidth: nil, equalHeights: true) { columns in
            header
                .detailPlacement(.full)
            cycleGroup
            if columns == .two, model.bars.count > 1 {
                chart.detailPlacement(.side)
            }
            if !model.workflows.isEmpty {
                AppWorkflowsTable(model: model, swatch: swatch, showsMinutes: showsMinutes, now: now, openWorkflow: openWorkflow, openBuild: openBuild)
                    .detailPlacement(.full)
            }
            testFlightSection
                .detailPlacement(.full)
            if columns == .two {
                if !model.references.isEmpty {
                    AppReferencesGroup(references: model.references, now: now, openReference: openReference)
                }
                if !AppNotesGroup.isEmpty(model) {
                    AppNotesGroup(model: model, openBuild: openBuild).detailPlacement(.side)
                }
            } else {
                if model.bars.count > 1 {
                    chart
                }
                ViewThatFits(in: .horizontal) {
                    // An ideal width of its own: the two groups go side by side as soon as there is that much room,
                    // however long a sentence of theirs would run on one line.
                    HStack(alignment: .top, spacing: 14) { footGroups }.frame(minWidth: 560, idealWidth: 560)
                    VStack(alignment: .leading, spacing: 14) { footGroups }
                }
            }
        }
        .navigationTitle(model.displayName)
    }

    @ViewBuilder
    private var testFlightSection: some View {
        if model.shipsToTestFlight {
            if !access.allows(.testFlightTracking) {
                ProLockedCard(feature: .testFlightTracking)
            } else if let testFlightCard {
                TestFlightCard(content: testFlightCard, appName: model.displayName, swatch: swatch)
            }
        }
    }

    private var chart: some View {
        AppBuildsChart(bars: model.bars, medianQueueWait: model.medianQueueWait, swatch: swatch, openBuild: openBuild)
    }

    @ViewBuilder
    private var footGroups: some View {
        if !model.references.isEmpty {
            AppReferencesGroup(references: model.references, now: now, openReference: openReference)
        }
        if !AppNotesGroup.isEmpty(model) {
            AppNotesGroup(model: model, openBuild: openBuild)
        }
    }

    /// No figure of minutes without a cycle, nor while the builds it rests on are still being measured.
    private var showsMinutes: Bool {
        model.cycle.map { !$0.isMeasuring } ?? false
    }

    /// The pill sits beside the name when both fit, under it otherwise: the name is never cut to make room.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                icon
                titles
                Spacer(minLength: 8)
                pill
            }
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    titles
                    pill
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var icon: some View {
        AppIconView(name: model.displayName, swatch: swatch, size: 40, artwork: artwork)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(UsageFormat.dotted([model.productKey == model.displayName ? nil : model.productKey, model.repository].compactMap(\.self)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var pill: some View {
        if let testFlight {
            TestFlightPill(text: testFlight)
        } else if isTestFlightPending {
            TestFlightPill(text: "TestFlight: build 386 · 4d").skeleton(true)
        }
    }

    @ViewBuilder
    private var cycleGroup: some View {
        if let cycle = model.cycle {
            // Measured builds are the ones the figures rest on: until then the card is the shape of what will stand there.
            let shown = cycle.isMeasuring ? AppOverviewModel.Cycle.placeholder : cycle
            VStack(alignment: .leading, spacing: 9) {
                figures(shown, isMeasuring: cycle.isMeasuring)
                AppCycleBar(segments: shown.segments, quotaMinutes: shown.quotaMinutes, swatch: swatch)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("This app used \(UsageFormat.percent(shown.fractionOfPlan)) of the plan"))
                    .accessibilityAddTraits(.isImage)
                legend(shown)
            }
            .skeleton(cycle.isMeasuring, label: "Measuring usage…")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cumulusGroup()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Set your plan’s reset date to see this app’s share of the cycle.", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Button("Set Your Plan…", action: openSettings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cumulusGroup()
        }
    }

    private func figures(_ cycle: AppOverviewModel.Cycle, isMeasuring: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                used(cycle, isMeasuring: isMeasuring)
                share(cycle)
                Spacer(minLength: 8)
                projection(cycle)
            }
            VStack(alignment: .leading, spacing: 2) {
                used(cycle, isMeasuring: isMeasuring)
                share(cycle)
                projection(cycle)
            }
        }
    }

    private func used(_ cycle: AppOverviewModel.Cycle, isMeasuring: Bool) -> some View {
        Group {
            if isMeasuring {
                Text("Measuring usage…").unredacted()
            } else {
                Text(AppOverviewText.minutes(billed: cycle.billedMinutes, estimated: cycle.estimatedMinutes))
            }
        }
        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }

    private func share(_ cycle: AppOverviewModel.Cycle) -> some View {
        let plan = String(localized: "of the \(UsageFormat.minutes(cycle.quotaMinutes)) plan", comment: "After an app's minutes: the size of the plan they are taken from")
        let account = cycle.shareOfUsed.map {
            String(localized: "\(UsageFormat.percent($0)) of what the account used this cycle", comment: "An app's share of everything the account used in the cycle")
        }
        return Text(UsageFormat.dotted([plan, UsageFormat.percent(cycle.fractionOfPlan), account].compactMap(\.self)))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private func projection(_ cycle: AppOverviewModel.Cycle) -> some View {
        if let projected = cycle.projectedMinutes, cycle.totalMinutes > 0 {
            Text("≈ \(UsageFormat.minutes(projected)) by the end of the cycle", comment: "What an app will have used when the cycle resets, at its current pace")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func legend(_ cycle: AppOverviewModel.Cycle) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(cycle.segments) { segment in
                HStack(spacing: 6) {
                    SwatchSquare(fill: AppCycleBar.fill(segment, swatch: swatch))
                    Text(segment.workflow ?? String(localized: "Other apps", comment: "Legend of an app's cycle bar: what the account's other apps used"))
                        .lineLimit(1)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The plan as a track: this app's workflows in shades of its colour, the other apps in grey, the rest left empty.
struct AppCycleBar: View {
    let segments: [AppOverviewModel.Segment]
    let quotaMinutes: Double
    let swatch: AppSwatch
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        GeometryReader { geometry in
            let widths = GaugeLayout.widths(minutes: segments.map(\.minutes), quotaMinutes: quotaMinutes, totalWidth: geometry.size.width)
            HStack(spacing: 2) {
                ForEach(Array(zip(segments, widths)), id: \.0.id) { segment, width in
                    Rectangle()
                        .fill(redaction.isSkeleton ? AnyShapeStyle(Color.skeleton) : Self.fill(segment, swatch: swatch))
                        .frame(width: max(0, width - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.primary.opacity(0.08))
        .clipShape(.capsule)
    }

    static func fill(_ segment: AppOverviewModel.Segment, swatch: AppSwatch) -> AnyShapeStyle {
        segment.workflow == nil ? AnyShapeStyle(Color.primary.opacity(0.28)) : AnyShapeStyle(swatch.color.opacity(segment.shade))
    }
}

/// The app's workflows side by side: last build, how the builds go, what they cost, what comes next. A wide column
/// gets the table; a narrow one gets each workflow on two lines.
struct AppWorkflowsTable: View {
    let model: AppOverviewModel
    let swatch: AppSwatch
    let showsMinutes: Bool
    let now: Date
    let openWorkflow: (String) -> Void
    let openBuild: (String) -> Void

    private static let rateWidth: CGFloat = 62
    private static let durationWidth: CGFloat = 104
    private static let minutesWidth: CGFloat = 98
    private static let nextWidth: CGFloat = 104

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide.frame(minWidth: showsMinutes ? 600 : 530)
            narrow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    // MARK: The table

    private var wide: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                heading("Workflow").frame(maxWidth: .infinity, alignment: .leading)
                heading("Last build").frame(maxWidth: .infinity, alignment: .leading)
                heading("Success").frame(width: Self.rateWidth, alignment: .trailing)
                heading("Median duration").frame(width: Self.durationWidth, alignment: .trailing)
                if showsMinutes {
                    heading("This cycle").frame(width: Self.minutesWidth, alignment: .trailing)
                }
                heading("Next").frame(width: Self.nextWidth, alignment: .trailing)
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)
            ForEach(model.workflows) { row in
                Divider()
                wideRow(row)
            }
            Divider()
            totalRow
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func wideRow(_ row: AppOverviewModel.WorkflowRow) -> some View {
        let coming = AppOverviewText.next(row.next, now: now)
        return HStack(alignment: .top, spacing: 10) {
            name(row).frame(maxWidth: .infinity, alignment: .leading)
            lastBuild(row).frame(maxWidth: .infinity, alignment: .leading)
            cell(AppOverviewText.rate(row.successRate), detail: AppOverviewText.drift(row.successDrift), tint: tint(row.successDrift, lowerIsBetter: false))
                .frame(width: Self.rateWidth, alignment: .trailing)
            cell(AppOverviewText.duration(row.medianDuration), detail: AppOverviewText.drift(row.durationDrift), tint: tint(row.durationDrift, lowerIsBetter: true))
                .frame(width: Self.durationWidth, alignment: .trailing)
            if showsMinutes {
                cell(
                    AppOverviewText.minutes(row.cycleMinutes ?? 0, isEstimated: row.isEstimated),
                    detail: row.cycleBuilds > 0 ? String(localized: "\(row.cycleBuilds) builds") : nil
                )
                .frame(width: Self.minutesWidth, alignment: .trailing)
            }
            cell(coming.title, detail: coming.detail).frame(width: Self.nextWidth, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { openWorkflow(row.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppOverviewText.spoken(row, showsMinutes: showsMinutes, now: now)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens this workflow"))
        .accessibilityAction { openWorkflow(row.id) }
        .accessibilityActions {
            if let run = row.lastRun {
                Button("Open the last build") { openBuild(run.id) }
            }
        }
    }

    private var totalRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("The app", comment: "Last row of the table of an app's workflows: the figures for the app as a whole")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            cell(AppOverviewText.rate(model.total.successRate), detail: nil).frame(width: Self.rateWidth, alignment: .trailing)
            cell(AppOverviewText.duration(model.total.medianDuration), detail: nil).frame(width: Self.durationWidth, alignment: .trailing)
            if showsMinutes {
                cell(AppOverviewText.minutes(model.total.cycleMinutes ?? 0, isEstimated: model.total.isEstimated), detail: nil)
                    .frame(width: Self.minutesWidth, alignment: .trailing)
            }
            Group {
                if let upcoming = model.total.upcomingMinutes, showsMinutes {
                    Text("~\(UsageFormat.minutes(upcoming)) to come", comment: "Total row of an app's workflows: estimated minutes of its scheduled builds until the cycle resets")
                        .font(.callout.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                } else {
                    Text(verbatim: "")
                }
            }
            .frame(width: Self.nextWidth, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 9)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
    }

    // MARK: Cells

    private func name(_ row: AppOverviewModel.WorkflowRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(swatch.color.opacity(row.shade))
                    .frame(width: 9, height: 9)
                Text(row.name).fontWeight(.semibold).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(AppOverviewText.workflowDetail(row)).lineLimit(1)
                if let warning = row.xcodeWarning {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(BuildStatus.errored.tint)
                        .help(Text("\(warning.latest) is available", comment: "Tooltip on a workflow that builds with an older Xcode; the argument is “Xcode 27.1”"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lastBuild(_ row: AppOverviewModel.WorkflowRow) -> some View {
        if let run = row.lastRun, let status = row.lastStatus {
            Button {
                openBuild(run.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.statusLine(status, number: run.number))
                        .font(.callout)
                        .lineLimit(1)
                    Text(AppOverviewText.lastBuildDetail(run, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open this build")
        } else {
            Text("no build yet", comment: "VoiceOver and table cell: the workflow has never built in what the app knows")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// “Failed · #395”, the state alone in its colour, like on a build's card.
    static func statusLine(_ status: BuildStatus, number: Int?) -> AttributedString {
        var line = AttributedString(status.label)
        line.swiftUI.font = .callout.weight(.semibold)
        line.swiftUI.foregroundColor = status.textTint
        guard let number else { return line }
        return line + AttributedString(UsageFormat.dotted(["", "#\(number)"]))
    }

    private func cell(_ value: String, detail: String?, tint: Color = .secondary) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func tint(_ drift: WorkflowTrends.Drift?, lowerIsBetter: Bool) -> Color {
        WorkflowTrendsSection.driftTint(drift, lowerIsBetter: lowerIsBetter)
    }

    // MARK: Narrow

    private var narrow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.workflows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                narrowRow(row)
            }
        }
    }

    private func narrowRow(_ row: AppOverviewModel.WorkflowRow) -> some View {
        let coming = AppOverviewText.next(row.next, now: now)
        let figures: [String?] = [
            row.successRate.map { AppOverviewText.rate($0) },
            row.medianDuration.map { AppOverviewText.duration($0) },
            showsMinutes ? row.cycleMinutes.map { AppOverviewText.minutes($0, isEstimated: row.isEstimated) } : nil,
            row.next == nil ? nil : [coming.title, coming.detail].compactMap(\.self).joined(separator: " "),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                name(row)
                Spacer(minLength: 8)
                lastBuild(row)
            }
            if !figures.compactMap(\.self).isEmpty {
                Text(UsageFormat.dotted(figures.compactMap(\.self)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { openWorkflow(row.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppOverviewText.spoken(row, showsMinutes: showsMinutes, now: now)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openWorkflow(row.id) }
    }
}
