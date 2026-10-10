import SwiftUI

/// The middle column: builds grouped by day along a rail of state dots, one glass card each.
struct BuildListView: View {
    let buildStore: BuildStore
    @Bindable var navigation: NavigationModel
    @State private var filter = BuildFilter.all
    @State private var query = ""

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .searchable(text: $query, prompt: Text("Number, commit or name"))
    }

    private func content(now: Date) -> some View {
        let model = BuildListModel(snapshot: buildStore.snapshot, scope: navigation.sidebarSelection, filter: filter, query: query, now: now)
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
                                        BuildCard(
                                            status: row.status, number: row.numberText, summary: row.summary(now: now), detail: row.detail,
                                            duration: row.duration(now: now), isSelected: row.id == navigation.selectedBuildID,
                                            spokenDetail: row.spokenDetail
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, in: model.rows) }
            .onKeyPress(.upArrow) { step(-1, in: model.rows) }
            .onChange(of: navigation.selectedBuildID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .safeAreaInset(edge: .top) { filterBar }
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
