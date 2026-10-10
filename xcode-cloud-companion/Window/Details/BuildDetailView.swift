import SwiftUI

/// The right column: a big number, the state in capsules, the actions frieze, the facts, the commit and the tabs.
struct BuildDetailView: View {
    let run: CIBuildRun
    let buildStore: BuildStore
    let extrasStore: BuildExtrasStore
    let artifactSaver: ArtifactSaver
    var onRebuild: (() -> Void)?
    let teamID: String?

    private enum Tab: Hashable {
        case actions, tests, problems, artifacts
    }

    @State private var tab = Tab.actions

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(BuildDetailModel(
                run: run,
                product: buildStore.snapshot.products.first { $0.id == run.productID },
                workflow: buildStore.snapshot.workflow(id: run.workflowID),
                actions: buildStore.snapshot.actionsByRunID[run.id] ?? [],
                teamID: teamID,
                now: context.date
            ))
        }
        .task(id: run) { await extrasStore.loadBetaBuilds(for: run) }
    }

    private func content(_ model: BuildDetailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(model)
                if !model.frieze.isEmpty {
                    ActionsFrieze(steps: model.frieze).cumulusGroup()
                }
                if !model.info.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        ForEach(model.info) { InfoItem(key: $0.title, value: $0.value, help: $0.help) }
                    }
                    .cumulusGroup()
                }
                if let commit = model.commit {
                    commitGroup(commit)
                }
                testFlightGroup
                tabs(model)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            if let onRebuild {
                ToolbarItem {
                    Button(action: onRebuild) {
                        Label("Rebuild", systemImage: "arrow.clockwise")
                    }
                    .help("Rebuild this build")
                }
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.open(model.appStoreConnectURL)
                } label: {
                    Label("Open in App Store Connect", systemImage: "arrow.up.forward.app")
                }
                .help("Open in App Store Connect")
            }
        }
        .navigationTitle(model.numberText)
        .navigationSubtitle(model.title)
    }

    private func header(_ model: BuildDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.numberText)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text(model.title)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                CapsuleTag(text: model.status.label, systemImage: model.status.systemImage, tint: model.status.tint)
                if let reference = model.reference {
                    CapsuleTag(text: reference, systemImage: "arrow.triangle.branch")
                }
                if let sha = model.shortSha {
                    CapsuleTag(text: sha, isMonospaced: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func commitGroup(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last commit")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if let message = commit.message {
                Text(message).lineLimit(4).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let author = commit.author {
                    Text(author).foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.sha, forType: .string)
                } label: {
                    Label(commit.shortSha, systemImage: "doc.on.doc")
                        .font(.system(.caption, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .help("Copy the commit SHA")
                if let url = commit.webURL {
                    Link("View commit", destination: url)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    @ViewBuilder
    private var testFlightGroup: some View {
        if let builds = extrasStore.extras(for: run.id)?.betaBuilds, !builds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("TestFlight")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                ForEach(builds) { build in
                    HStack {
                        Label(build.version.map { String(localized: "Build \($0)") } ?? String(localized: "Build"), systemImage: "paperplane")
                        Spacer()
                        if let state = build.processingState?.nilIfBlank {
                            Text(state.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cumulusGroup()
        }
    }

    private func tabs(_ model: BuildDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Details", selection: $tab) {
                Text(Self.title(String(localized: "Actions"), count: model.actions.count)).tag(Tab.actions)
                Text(Self.title(String(localized: "Tests"), suffix: model.testFailureCount.flatMap { $0 > 0 ? String(localized: "\($0) failed") : nil })).tag(Tab.tests)
                Text(Self.title(String(localized: "Issues"), count: model.issueCount)).tag(Tab.problems)
                Text("Artifacts").tag(Tab.artifacts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
            let extras = extrasStore.extras(for: run.id)
            switch tab {
            case .actions: actionsTab(model)
            case .tests:
                TestsTabView(
                    results: extras?.testsByAction ?? [:], actions: actions, state: extrasStore.state(.tests, runID: run.id),
                    retry: { Task { await extrasStore.loadTests(for: run, actions: actions) } }
                )
                .task(id: run) { await extrasStore.loadTests(for: run, actions: actions) }
            case .problems:
                IssuesTabView(
                    issues: extras?.issuesByAction ?? [:], actions: actions, state: extrasStore.state(.issues, runID: run.id),
                    retry: { Task { await extrasStore.loadIssues(for: run, actions: actions) } }
                )
                .task(id: run) { await extrasStore.loadIssues(for: run, actions: actions) }
            case .artifacts:
                ArtifactsTabView(
                    artifacts: extras?.artifactsByAction ?? [:], actions: actions, state: extrasStore.state(.artifacts, runID: run.id), saver: artifactSaver,
                    retry: { Task { await extrasStore.loadArtifacts(for: run, actions: actions) } }
                )
                .task(id: run) { await extrasStore.loadArtifacts(for: run, actions: actions) }
            }
        }
    }

    private func actionsTab(_ model: BuildDetailModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.actions) { action in
                HStack(spacing: 10) {
                    StatusBadge(status: action.status, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.name).fontWeight(.semibold)
                        let facts = [action.platform, action.destination, action.isRequired == true ? String(localized: "Required") : nil, action.issueSummary]
                        Text(UsageFormat.dotted(facts.compactMap(\.self))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let duration = action.duration {
                        Text(duration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if action.id != model.actions.last?.id { Divider() }
            }
            if model.actions.isEmpty {
                Text("No action recorded yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cumulusGroup()
    }

    private static func title(_ base: String, suffix: String?) -> String {
        suffix.map { UsageFormat.dotted([base, $0]) } ?? base
    }

    private static func title(_ base: String, count: Int?) -> String {
        guard let count, count > 0 else { return base }
        return UsageFormat.dotted([base, count.formatted()])
    }
}
