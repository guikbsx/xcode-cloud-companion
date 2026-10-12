import SwiftUI

/// The middle column under “Branches and pull requests”: each reference with its newest build, laid out like the
/// build list, by day along the same rail of state dots.
struct ReferencesListView: View {
    let buildStore: BuildStore
    let store: ReferencesStore
    let open: (ReferenceKey) -> Void
    var icons: AppIconStore?
    var palette = AppPalette()
    @State private var filter = ReferenceFilter.all
    @State private var query = ""

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
        return ScrollView {
            if model.hasNothing {
                ContentUnavailableView(
                    "No branch or pull request yet", systemImage: "arrow.triangle.branch",
                    description: Text("Branches, tags and pull requests appear here once Xcode Cloud has built one in the last 30 days.")
                )
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    "No matching reference", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change the filter or the search to see more.")
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.groups) { group in
                        DayHeader(title: group.title)
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            TimelineRow(status: row.status, isFirst: index == 0, isLast: index == group.rows.count - 1) {
                                Button {
                                    open(row.key)
                                } label: {
                                    BuildCard(reference: row, now: now, swatch: palette.swatch(for: row.productKey ?? row.productName), artwork: artwork[row.lastRun.productID])
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let url = row.webURL {
                                        Button("Open the pull request") { NSWorkspace.shared.open(url) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
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

extension BuildCard {
    /// A reference, on the build list's card: its name for a title, then its last build's state, workflow and number.
    init(reference row: ReferenceRow, now: Date, swatch: AppSwatch, artwork: AppArtwork?) {
        self.init(
            appName: row.productName, swatch: swatch, artwork: artwork,
            title: row.title, titleSymbol: row.key.isPullRequest ? "arrow.triangle.pull" : "arrow.triangle.branch",
            status: row.status, statusText: row.status.label, facts: row.facts,
            age: row.runningSince == nil ? row.age(now: now) : nil, runningSince: row.runningSince,
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
    return VStack(spacing: 8) {
        ForEach(model.rows) { BuildCard(reference: $0, now: Date(), swatch: .blue, artwork: nil) }
    }
    .padding(16)
    .frame(width: 372)
}
