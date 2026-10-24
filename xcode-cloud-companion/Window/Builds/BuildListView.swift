import SwiftUI

/// The middle column: builds grouped by day, one flat row each, led by the ring of its actions.
struct BuildListView: View {
    let buildStore: BuildStore
    @Bindable var navigation: NavigationModel
    var scope = BuildListScope.allBuilds
    /// Set while the list is one reference's or one day's: the way back, and what it is called.
    var back: (() -> Void)?
    var backTitle: LocalizedStringKey = "Branches and pull requests"
    /// Builds past the cache's window, read on request at the foot of the list.
    var older: OlderBuildsStore?
    /// The apps' colours and icons: where apps mix (all builds), a row names its app by the icon in its ring.
    var palette = AppPalette()
    var icons: AppIconStore?
    /// Copies a failed build as text for an AI assistant; nil leaves it out of the row's menu.
    var failureCopier: BuildFailureCopier?
    @State private var filter = BuildFilter.all
    @Environment(ProAccess.self) private var access: ProAccess?
    @State private var query = ""

    private static let blockID = "running-block"

    var body: some View {
        TickingView(interval: 60) { now in
            content(now: now)
        }
        .searchable(text: $query, prompt: Text("Number, commit or name"))
    }

    @ViewBuilder
    private func rowView(_ row: BuildRowData, isFirst: Bool, isLast: Bool, runs: [String: CIBuildRun], artwork: [String: AppArtwork], now: Date) -> some View {
        if let run = runs[row.id] {
            BuildRowRing(run: run, snapshot: buildStore.snapshot, now: now) { ring in
                BuildRow(
                    row: row, ring: ring, now: now, swatch: palette.swatch(for: row.productKey ?? row.productName),
                    showsApp: scope.mixesApps, artwork: artwork[row.productID]
                )
            }
            .contextMenu { failureMenu(for: row) }
            .listRowHover(isSelected: row.id == navigation.selectedBuildID)
            .listRowSeparator(isFirst ? .hidden : .automatic, edges: .top)
            .listRowSeparator(isLast ? .hidden : .automatic, edges: .bottom)
            .tag(row.id)
        }
    }

    @ViewBuilder
    private func failureMenu(for row: BuildRowData) -> some View {
        if let failureCopier, let run = (buildStore.snapshot.runs + (older?.runs ?? [])).first(where: { $0.id == row.id }),
           BuildFailurePrompt.isOffered(for: run) {
            Button {
                Task { await failureCopier.copy(run) }
            } label: {
                Label("Copy for AI", systemImage: "sparkles")
            }
        }
    }

    private func content(now: Date) -> some View {
        let model = BuildListModel(snapshot: buildStore.snapshot, olderRuns: older?.runs ?? [], scope: scope, filter: filter, query: query, splitsRunning: true, now: now)
        let runs = Dictionary(buildStore.snapshot.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .merging((older?.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { cached, _ in cached })
        let artwork = scope.mixesApps ? icons?.artwork(in: buildStore.snapshot, by: \.id) ?? [:] : [:]
        return ScrollViewReader { proxy in
            List(selection: $navigation.selectedBuildID) {
                if !model.runningRows.isEmpty {
                    RunningBlockView(
                        ids: model.runningIDs, more: model.moreRunning, snapshot: buildStore.snapshot, palette: palette, artwork: artwork,
                        selectedID: navigation.selectedBuildID, select: { navigation.selectedBuildID = $0 },
                        showMore: { filter = .running }
                    )
                    .id(Self.blockID)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                }
                if let reason = model.emptyReason {
                    emptyState(reason)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                rowView(row, isFirst: row.id == group.rows.first?.id, isLast: row.id == group.rows.last?.id, runs: runs, artwork: artwork, now: now)
                            }
                        } header: {
                            DayHeader(title: group.title)
                        }
                        .listSectionSeparator(.hidden, edges: .top)
                    }
                }
                if let older, let productIDs = olderProductIDs, !productIDs.isEmpty {
                    olderFooter(older, productIDs: productIDs)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .onChange(of: navigation.selectedBuildID) { _, id in
                guard let id else { return }
                withAnimation {
                    if model.runningIDs.contains(id) { proxy.scrollTo(Self.blockID, anchor: .top) } else { proxy.scrollTo(id) }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let back {
                        Button(action: back) {
                            Label(backTitle, systemImage: "chevron.left")
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
        case .reference, .workflowDay: return nil
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
