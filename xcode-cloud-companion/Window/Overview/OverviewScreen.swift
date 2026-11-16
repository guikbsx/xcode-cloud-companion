import SwiftUI

/// What the Overview does when a click leads somewhere: the window answers these.
struct OverviewScreenActions {
    var openBuild: (String) -> Void = { _ in }
    var openWorkflow: (String) -> Void = { _ in }
    var openApp: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openStatusPage: () -> Void = { NSWorkspace.shared.open(AppleStatusSchedule.statusPage) }
    /// Copies a failed build as text for an AI assistant, loading what its tabs would first.
    var copyForAI: (String) async -> Void = { _ in }
    /// “See the day” in the bubble of a square: the builds of this workflow (its ID) on this day (its start), listed.
    var showDay: (String, Date) -> Void = { _, _ in }
}

/// The Overview, as a front page: the line of the day, the headline, the figure of the last days by workflow, the small
/// notes, and under them, folded, the details of the cycle. It reads what the app already holds and asks Apple for nothing.
struct OverviewScreen<Detail: View>: View {
    let session: AccountSession
    let palette: AppPalette
    let summary: UsageSummary?
    /// The icons of the apps, by product ID.
    var artwork: [String: AppArtwork] = [:]
    var actions = OverviewScreenActions()
    @ViewBuilder var detail: () -> Detail

    @Environment(AppleStatusStore.self) private var appleStatus: AppleStatusStore?
    @State private var flakyTests: [OverviewFlakyTests.Entry] = []

    private var buildStore: BuildStore { session.buildStore }

    var body: some View {
        let snapshot = buildStore.snapshot
        TickingView(interval: 60) { now in
            let model = makeModel(snapshot: snapshot, now: now)
            OverviewScreenBody(model: model, artwork: artwork, actions: actions, now: now, detail: detail)
        }
        .navigationTitle("Overview")
        .task(id: ReadKey(sync: snapshot.lastSuccessfulSync, runs: snapshot.runs.count)) {
            let workflowIDs = Array(Set(snapshot.runs.compactMap(\.workflowID))).sorted()
            flakyTests = await OverviewFlakyTests.read(workflowIDs: workflowIDs, in: snapshot, cache: BuildExtrasCache(directory: session.paths.buildDetails))
        }
        .task(id: Self.failedHeads(in: snapshot)) {
            await session.failureInsights.loadCached(runIDs: Self.failedHeads(in: snapshot))
        }
    }

    private struct ReadKey: Hashable {
        let sync: Date?
        let runs: Int
    }

    private func makeModel(snapshot: BuildSnapshot, now: Date) -> OverviewScreenModel {
        let isReading = SkeletonRules.overviewMosaic(
            isMeasuring: session.measurement(now: now, summary: summary).isMeasuring,
            isFirstSync: buildStore.isSyncing && snapshot.lastSuccessfulSync == nil
        )
        let insights: [String: String] = session.failureInsights.isOpen()
            ? session.failureInsights.records.compactMapValues { $0.headline?.nilIfBlank }
            : [:]
        let categories: [String: FailureCategory] = session.failureInsights.isOpen()
            ? session.failureInsights.records.mapValues(\.category)
            : [:]
        var testFlight: [String: TestFlightReading] = [:]
        for product in snapshot.products {
            testFlight[product.id] = session.testFlight.reading(for: product.id)
        }
        return OverviewScreenModel(
            snapshot: snapshot, sidebar: SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: palette), summary: summary,
            ledger: session.usageStore.ledger, accountName: session.name, isReading: isReading, now: now,
            failureInsights: insights, failureCategories: categories, appleStatus: appleStatus?.knowledge,
            testFlight: testFlight, flakyTests: flakyTests
        )
    }

    /// The newest finished build of each workflow when it failed: the ones the Overview may quote “In brief” for.
    static func failedHeads(in snapshot: BuildSnapshot) -> [String] {
        let finished = snapshot.runs.filter { $0.executionProgress == .complete && $0.workflowID != nil }
        return Dictionary(grouping: finished, by: { $0.workflowID ?? "" }).values.compactMap { runs -> String? in
            let newest = runs.max { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            guard let newest, newest.completionStatus == .failed || newest.completionStatus == .errored else { return nil }
            return newest.id
        }
        .sorted()
    }
}

private let overviewMargin: CGFloat = 24

/// The scrolling page. It owns the width of its column, so a resize redraws the layout and nothing is worked out again.
struct OverviewScreenBody<Detail: View>: View {
    let model: OverviewScreenModel
    let artwork: [String: AppArtwork]
    let actions: OverviewScreenActions
    let now: Date
    /// What is open on the figure; a test gives its own to render a bubble or a drawer open.
    var interaction: OverviewFigureInteraction?
    @ViewBuilder var detail: () -> Detail

    @State private var width: CGFloat = 1000
    @Environment(\.calendar) private var calendar

    private var contentWidth: CGFloat { max(width - 2 * overviewMargin, 320) }

    private var layout: OverviewFigureLayout {
        OverviewFigureLayout.make(
            width: contentWidth, showsCycle: model.showsCycle, availableDays: model.mosaic.days.count, hasNotes: !model.notes.isEmpty
        )
    }

    var body: some View {
        let layout = layout
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OverviewAccountLineView(line: model.accountLine, openBuild: actions.openBuild, openSettings: actions.openSettings)
                OverviewTitleView(
                    title: model.title, width: contentWidth, copyForAI: actions.copyForAI,
                    perform: { perform($0) }
                )
                .padding(.top, 14)
                if model.phase != .empty {
                    figureSection(layout)
                        .padding(.top, 20)
                }
                detailSection
                    .padding(.top, 28)
            }
            .padding(.horizontal, overviewMargin)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Figure

    @ViewBuilder
    private func figureSection(_ layout: OverviewFigureLayout) -> some View {
        let isReading = model.phase == .reading
        let figure = VStack(alignment: .leading, spacing: 10) {
            OverviewFigureCaption(
                days: layout.days, today: now, width: layout.figureWidth, showsCycle: layout.showsCycle,
                cycleIsEstimated: model.hasEstimatedCycle
            )
            OverviewFigureView(
                mosaic: model.mosaic, layout: layout, seriesColor: OverviewColors.ink(model.title.tone), cycleIsEstimated: model.hasEstimatedCycle,
                calendar: calendar, artwork: artwork, now: now, openWorkflow: actions.openWorkflow, openApp: actions.openApp,
                openBuild: actions.openBuild, showDay: actions.showDay, details: model.detail, interaction: interaction
            )
        }
        .skeleton(isReading, label: "Reading your builds…")
        // A bubble drawn inline overflows the figure: it stays above the notes.
        .zIndex(1)
        switch layout.notes {
        case .beside:
            HStack(alignment: .top, spacing: OverviewFigureLayout.notesGap) {
                figure
                OverviewNotesView(notes: model.notes, placement: .beside, width: notesWidth(layout), open: { open($0) })
                    .frame(maxWidth: OverviewFigureLayout.notesMaximumWidth, alignment: .leading)
                    .padding(.top, 40)
            }
        case .below:
            VStack(alignment: .leading, spacing: 18) {
                figure
                OverviewNotesView(notes: model.notes, placement: .below, width: contentWidth, open: { open($0) })
            }
        }
    }

    private func notesWidth(_ layout: OverviewFigureLayout) -> CGFloat {
        min(OverviewFigureLayout.notesMaximumWidth, contentWidth - layout.figureWidth - OverviewFigureLayout.notesGap)
    }

    // MARK: Detail

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cycle Details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
            detail()
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(OverviewColors.rule).frame(height: 1) }
    }

    // MARK: Clicks

    private func perform(_ action: OverviewHeadline.Action) {
        switch action {
        case .openBuild(let id): actions.openBuild(id)
        case .copyForAI: break
        case .openWorkflow(let id): actions.openWorkflow(id)
        case .openAppleStatusPage: actions.openStatusPage()
        }
    }

    private func open(_ target: OverviewHeadline.Target) {
        switch target {
        case .build(let id): actions.openBuild(id)
        case .workflow(let id): actions.openWorkflow(id)
        case .app(let id): actions.openApp(id)
        case .appleStatusPage: actions.openStatusPage()
        }
    }
}

/// Above the mosaic: what the figure is, on the left, and the key to its colours, on the right.
private struct OverviewFigureCaption: View {
    let days: Int
    let today: Date
    let width: CGFloat
    let showsCycle: Bool
    let cycleIsEstimated: Bool
    @Environment(\.calendar) private var calendar

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                caption
                Spacer(minLength: 0)
                legend
            }
            VStack(alignment: .leading, spacing: 8) {
                caption
                legend
            }
        }
        .frame(width: width, alignment: .leading)
        .unredacted()
    }

    private var caption: some View {
        let words = OverviewScreenWords(calendar: calendar)
        let date = words.longDay(today)
        var title = AttributedString(String(localized: "Fig. 1", comment: "Number of the figure of the Overview, in bold before its caption"))
        title.font = .system(size: 12, weight: .bold)
        let sentence = String(localized: "  Daily outcome of builds, by workflow. \(days) days up to \(date).", comment: "Caption of the Overview's figure. The placeholders are a number of days and a date such as “Thursday, October 23”. Keep the two spaces at the start.")
        return VStack(alignment: .leading, spacing: 1) {
            Text(title + AttributedString(sentence)).font(.system(size: 12))
            Text(secondLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var secondLine: LocalizedStringKey {
        guard showsCycle else { return "Success rate and median duration: last 7 days." }
        return cycleIsEstimated
            ? "Success rate and median duration: last 7 days. Cycle minutes: since the reset, estimated, not official."
            : "Success rate and median duration: last 7 days. Cycle minutes: since the reset."
    }

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 12) {
                key(OverviewColors.succeeded, "all succeeded")
                key(OverviewColors.failed, "at least one failure")
                key(OverviewColors.mixed, "both")
                key(OverviewColors.empty, "no build")
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("builds of the day")
                    HStack(spacing: 2) {
                        ForEach(0..<OverviewColors.strengths.count, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3).fill(OverviewColors.succeeded.opacity(OverviewColors.strengths[index])).frame(width: 11, height: 11)
                        }
                    }
                    Text("1 to 4+")
                }
                HStack(spacing: 5) {
                    Circle().fill(OverviewColors.running).frame(width: 9, height: 9)
                    Text("running")
                }
                HStack(spacing: 5) {
                    Circle().strokeBorder(OverviewColors.running, lineWidth: 1.6).frame(width: 8, height: 8)
                    Text("queued")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func key(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(title)
        }
    }
}
