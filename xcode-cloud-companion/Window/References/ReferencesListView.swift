import SwiftUI

/// The middle column under “Branches and pull requests”: each reference with its newest build, laid out like the
/// build list, by day, with the ring of its last build.
struct ReferencesListView: View {
    let buildStore: BuildStore
    let store: ReferencesStore
    let open: (AppReference) -> Void
    var palette = AppPalette()
    var icons: AppIconStore?
    @State private var filter = ReferenceFilter.all
    @State private var query = ""
    @State private var highlighted: AppReference?

    var body: some View {
        TickingView(interval: 60) { now in
            content(now: now)
        }
        .searchable(text: $query, prompt: Text("Branch, tag or pull request"))
        .task(id: buildStore.snapshot.runs.count) { await store.load(snapshot: buildStore.snapshot) }
    }

    private func content(now: Date) -> some View {
        let model = ReferencesModel(snapshot: buildStore.snapshot, openPullRequests: store.openPullRequests, filter: filter, query: query, now: now)
        let artwork = icons?.artwork(in: buildStore.snapshot, by: \.id) ?? [:]
        let rows = Dictionary(model.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List(selection: $highlighted) {
            if model.hasNothing {
                ContentUnavailableView(
                    "No branch or pull request yet", systemImage: "arrow.triangle.branch",
                    description: Text("Branches, tags and pull requests appear here once Xcode Cloud has built one in the last 30 days.")
                )
                .frame(maxWidth: .infinity)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    "No matching reference", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change the filter or the search to see more.")
                )
                .frame(maxWidth: .infinity)
                .selectionDisabled()
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button {
                                open(row.reference)
                            } label: {
                                BuildRowRing(run: row.lastRun, snapshot: buildStore.snapshot, now: now) { ring in
                                    BuildRow(
                                        reference: row, ring: ring, now: now, swatch: palette.swatch(for: row.productKey ?? row.productName),
                                        artwork: artwork[row.lastRun.productID]
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowHover(isSelected: row.reference == highlighted)
                            .listRowSeparator(row.id == group.rows.first?.id ? .hidden : .automatic, edges: .top)
                            .listRowSeparator(row.id == group.rows.last?.id ? .hidden : .automatic, edges: .bottom)
                            .tag(row.reference)
                        }
                    } header: {
                        DayHeader(title: group.title)
                    }
                    .listSectionSeparator(.hidden, edges: .top)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: AppReference.self) { ids in
            if let url = ids.first.flatMap({ rows[$0] })?.webURL {
                Button("Open the pull request") { NSWorkspace.shared.open(url) }
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                Picker("Kind", selection: $filter) {
                    Text("All").tag(ReferenceFilter.all)
                    Text("Pull requests").tag(ReferenceFilter.pullRequests)
                    Text("Branches").tag(ReferenceFilter.branches)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if store.loadFailed {
                    Label("The open pull requests couldn’t be read: closed ones may still show.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle(Text("Branches and pull requests"))
        .navigationSubtitle(Text("\(model.rows.count) references", comment: "Count under the title of the view by branch and pull request"))
    }
}

extension BuildRow {
    /// A reference, on the build list's row: its name for a title, then its last build's number, workflow and branches.
    init(reference row: ReferenceRow, ring: BuildRing, now: Date, swatch: AppSwatch, artwork: AppArtwork? = nil) {
        self.init(
            appName: row.productName, swatch: swatch, ring: ring,
            title: row.title, titleSymbol: row.key.isPullRequest ? "arrow.triangle.pull" : "arrow.triangle.branch",
            statusText: row.status.rowWord(failedTests: row.lastRun.issueCounts?.testFailures ?? 0), statusTint: row.status.textTint,
            facts: row.facts, age: row.runningSince == nil ? row.age(now: now) : nil, showsApp: true, artwork: artwork,
            runningSince: row.runningSince,
            spokenLabel: "\(row.title), \(row.status.label)", spokenValue: row.spokenDetail
        )
    }
}

#Preview("Références") {
    let runs = [
        CIBuildRun(
            id: "r1", productID: "a", number: 394, createdDate: Date(), startedDate: Date().addingTimeInterval(-250), finishedDate: nil, executionProgress: .running,
            completionStatus: nil, startReason: nil, workflowID: "w1", workflowName: "Release", sourceBranchOrTag: "main"
        ),
        CIBuildRun(
            id: "r2", productID: "a", number: 393, createdDate: Date().addingTimeInterval(-3600), startedDate: nil, finishedDate: nil, executionProgress: .complete,
            completionStatus: .failed, startReason: nil, workflowID: "w2", workflowName: "PR Checks", sourceBranchOrTag: "fix/csv-import",
            isPullRequestBuild: true, pullRequestNumber: 131, pullRequestTitle: "Fix the CSV import"
        ),
    ]
    let product = CIProduct(id: "a", name: "Cumulus", productType: "APP", appID: "1", appName: nil, bundleID: nil)
    let model = ReferencesModel(snapshot: BuildSnapshot(products: [product], runs: runs, workflows: []), openPullRequests: nil)
    let snapshot = BuildSnapshot(products: [product], runs: runs, workflows: [])
    return VStack(spacing: 0) {
        ForEach(model.rows) { row in
            BuildRowRing(run: row.lastRun, snapshot: snapshot, now: Date()) { ring in
                BuildRow(reference: row, ring: ring, now: Date(), swatch: .blue)
            }
        }
    }
    .padding(8)
    .frame(width: 372)
}
