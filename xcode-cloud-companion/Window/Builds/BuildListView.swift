import SwiftUI

/// The middle column: builds grouped by day along a rail of state dots, one glass card each.
struct BuildListView: View {
    let buildStore: BuildStore
    @Bindable var navigation: NavigationModel
    var scope = BuildListScope.allBuilds
    /// Set while the list is one reference's: the way back to the references.
    var back: (() -> Void)?
    /// Builds past the cache's window, read on request at the foot of the list.
    var older: OlderBuildsStore?
    /// The apps' icons and colours: a card names its app by its icon.
    var icons: AppIconStore?
    var palette = AppPalette()
    @State private var filter = BuildFilter.all
    @Environment(ProAccess.self) private var access: ProAccess?
    @State private var query = ""

    var body: some View {
        TickingView(interval: 60) { now in
            content(now: now)
        }
        .searchable(text: $query, prompt: Text("Number, commit or name"))
    }

    private func card(_ row: BuildRowData, now: Date, artwork: [String: AppArtwork]) -> BuildCard {
        BuildCard(
            row: row, now: now, swatch: palette.swatch(for: row.productKey ?? row.productName), artwork: artwork[row.productID],
            isSelected: row.id == navigation.selectedBuildID
        )
    }

    private func content(now: Date) -> some View {
        let model = BuildListModel(snapshot: buildStore.snapshot, olderRuns: older?.runs ?? [], scope: scope, filter: filter, query: query, now: now)
        let artwork = icons?.artwork(in: buildStore.snapshot, by: \.id) ?? [:]
        return ScrollViewReader { proxy in
            ScrollView {
                if let reason = model.emptyReason {
                    emptyState(reason)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.groups) { group in
                            DayHeader(title: group.title)
                            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                TimelineRow(status: row.status, isFirst: index == 0, isLast: index == group.rows.count - 1) {
                                    Button {
                                        navigation.selectedBuildID = row.id
                                    } label: {
                                        card(row, now: now, artwork: artwork)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                if let older, let productIDs = olderProductIDs, !productIDs.isEmpty {
                    olderFooter(older, productIDs: productIDs)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, in: model.rows) }
            .onKeyPress(.upArrow) { step(-1, in: model.rows) }
            .onChange(of: navigation.selectedBuildID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let back {
                        Button(action: back) {
                            Label("Branches and pull requests", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CumulusStyle.accent)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    filterBar
                    if model.isPausedWorkflow {
                        Label("This workflow is paused: no build starts until it is resumed.", systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationSubtitle(Text("\(model.count) builds"))
        }
    }

    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            Text("All").tag(BuildFilter.all)
            Text("Running").tag(BuildFilter.running)
            Text("Failures").tag(BuildFilter.failed)
            Text("TestFlight").tag(BuildFilter.testFlight)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The products whose older builds the foot of the list can ask for; nil where older pages mean nothing.
    private var olderProductIDs: [String]? {
        let snapshot = buildStore.snapshot
        switch scope {
        case .allBuilds: return snapshot.products.map(\.id)
        case .product(let id): return [id]
        case .workflow(let id):
            let productID = snapshot.workflow(id: id)?.productID ?? snapshot.runs.first { $0.workflowID == id }?.productID
            return productID.map { [$0] }
        case .reference: return nil
        }
    }

    @ViewBuilder
    private func olderFooter(_ older: OlderBuildsStore, productIDs: [String]) -> some View {
        let isLoading = productIDs.contains { older.isLoading($0) }
        let allExhausted = productIDs.allSatisfy { older.isExhausted($0) }
        VStack(spacing: 6) {
            if allExhausted {
                Text("No older builds.").font(.caption).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else if !access.allows(.olderBuilds) {
                Button("Load Older Builds", systemImage: "lock") {
                    access?.showPurchase(for: .olderBuilds)
                }
                .controlSize(.small)
                .help("Builds older than 35 days come with Cumulus Pro")
            } else {
                Button("Load Older Builds") {
                    Task {
                        for productID in productIDs where !older.isExhausted(productID) {
                            await older.loadOlder(productID: productID, known: buildStore.snapshot.runs(forProductID: productID))
                        }
                    }
                }
                .controlSize(.small)
            }
            if let message = older.lastError {
                Text(message).font(.caption).foregroundStyle(BuildStatus.errored.tint).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func step(_ offset: Int, in rows: [BuildRowData]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.id == navigation.selectedBuildID }
        let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? 0
        navigation.selectedBuildID = rows[next].id
        return .handled
    }

    @ViewBuilder
    private func emptyState(_ reason: BuildListEmptyReason) -> some View {
        switch reason {
        case .noBuilds:
            ContentUnavailableView(
                "No builds yet", systemImage: "cloud",
                description: Text("Builds of the last 30 days appear here once Xcode Cloud has run one.")
            )
        case .nothingMatches:
            ContentUnavailableView(
                "No matching build", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Change the filter or the search to see more.")
            )
        }
    }
}
