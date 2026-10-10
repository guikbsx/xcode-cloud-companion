import SwiftUI

/// The right column: a big number, the state in capsules, the actions frieze, the facts, the commit and the tabs.
struct BuildDetailView: View {
    let run: CIBuildRun
    let buildStore: BuildStore
    let extrasStore: BuildExtrasStore
    let artifactSaver: ArtifactSaver
    var onRebuild: (() -> Void)?
    let teamID: String?
    var icons: AppIconStore?
    var palette = AppPalette()
    var openBuild: (String) -> Void = { _ in }
    var logOpener: LogOpener?

    @Binding var tab: BuildTab

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
                    ActionsFrieze(
                        steps: model.frieze,
                        logSteps: Set(model.frieze.filter { ($0.status == .failed || $0.status == .errored) && offersLogs($0.id) }.map(\.id)),
                        busyLogSteps: Set(model.frieze.filter { logOpener?.state(of: $0.id).isBusy == true }.map(\.id)),
                        openLogs: { openLogs(of: $0, model: model) }
                    )
                    .cumulusGroup()
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
                RegressionGroup(run: run, buildStore: buildStore, extrasStore: extrasStore, openBuild: openBuild).id(run.id)
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
            HStack(alignment: .center, spacing: 14) {
                if let product = buildStore.snapshot.product(id: run.productID) {
                    AppIconView(
                        name: product.displayName, swatch: palette.swatch(for: product.name), lastStatus: model.status, size: 44,
                        artwork: icons?.artwork(of: product, in: buildStore.snapshot)
                    )
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.numberText)
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    Text(model.title)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
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
                Text(Self.title(String(localized: "Actions"), count: model.actions.count)).tag(BuildTab.actions)
                Text(Self.title(String(localized: "Tests"), suffix: model.testFailureCount.flatMap { $0 > 0 ? String(localized: "\($0) failed") : nil })).tag(BuildTab.tests)
                Text(Self.title(String(localized: "Issues"), count: model.issueCount)).tag(BuildTab.problems)
                Text("Artifacts").tag(BuildTab.artifacts)
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

    // MARK: - Logs

    private func action(_ id: String) -> CIBuildAction? {
        buildStore.snapshot.actionsByRunID[run.id]?.first { $0.id == id }
    }

    private func knownArtifacts(of actionID: String) -> [CIArtifact]? {
        extrasStore.extras(for: run.id)?.artifactsByAction[actionID]
    }

    private func offersLogs(_ actionID: String) -> Bool {
        guard let logOpener, let action = action(actionID) else { return false }
        return logOpener.offersLogs(for: action, knownArtifacts: knownArtifacts(of: actionID))
    }

    private func openLogs(of actionID: String, model: BuildDetailModel) {
        guard let action = action(actionID) else { return }
        let name = model.actions.first { $0.id == actionID }?.name ?? ""
        let title = [[model.appName, model.numberText].compactMap(\.self).joined(separator: " "), name].filter { !$0.isEmpty }.joined(separator: " – ")
        logOpener?.start(action, run: run, knownArtifacts: knownArtifacts(of: actionID), title: title)
    }

    @ViewBuilder
    private func logsControl(for actionID: String, model: BuildDetailModel) -> some View {
        switch logOpener?.state(of: actionID) ?? .idle {
        case .preparing, .unpacking:
            ProgressView().controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 70)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { logOpener?.cancel(actionID) }.controlSize(.small)
            }
        case .idle, .failed:
            if offersLogs(actionID) {
                Button {
                    openLogs(of: actionID, model: model)
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .help("Download this action’s logs and open them in the Finder")
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
                    logsControl(for: action.id, model: model)
                    if let duration = action.duration {
                        Text(duration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if case .failed(let message)? = logOpener?.state(of: action.id) {
                    Text(message).font(.caption).foregroundStyle(BuildStatus.errored.tint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
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
