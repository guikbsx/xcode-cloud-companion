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
    /// The imported usage exports: what the build cost, when it can be told.
    var ledger: UsageLedger?
    /// The “In Brief” summaries of failed builds; without one the card and the suggested groups do not exist.
    var insights: FailureInsightStore?

    @Binding var tab: BuildTab
    /// Bumped by “Compare with #n” beside the commit: the group below starts its comparison.
    @State private var compareRequest = 0
    /// The build whose TestFlight builds have been asked for, answered or not.
    @State private var betaEndedRunID: String?
    @Environment(ProAccess.self) private var access: ProAccess?
    @AppStorage(FailureInsightFeature.settingKey) private var isInsightSettingOn = true

    var body: some View {
        TickingView(interval: Self.redrawInterval(for: run)) { now in
            content(BuildDetailModel(
                run: run,
                product: buildStore.snapshot.products.first { $0.id == run.productID },
                workflow: buildStore.snapshot.workflow(id: run.workflowID),
                actions: buildStore.snapshot.actionsByRunID[run.id] ?? [],
                teamID: teamID,
                now: now,
                cost: ledger.flatMap { UsageCalculator.cost(of: run, in: buildStore.snapshot, ledger: $0, now: now) }
            ))
        }
        .task(id: run) {
            await extrasStore.loadBetaBuilds(for: run)
            betaEndedRunID = run.id
        }
    }

    /// A running build's durations go on every second until a sync says it ended; a finished build only has its
    /// "2 hours ago" to keep up to date.
    nonisolated static func redrawInterval(for run: CIBuildRun) -> TimeInterval {
        run.executionProgress == .complete ? 60 : 1
    }

    private func content(_ model: BuildDetailModel) -> some View {
        DetailScroll { columns in
            // Read first on two columns as well: who the build is and how it went, then its context.
            identityCard(model, columns: columns)
                .accessibilitySortPriority(columns == .two ? 1 : 0)
            if columns == .one, !model.frieze.isEmpty {
                frieze(model).padding(.horizontal, 8)
            }
            if BuildFailurePrompt.isOffered(for: run) {
                if let insights {
                    FailureInsightSection(run: run, store: insights)
                        .id(run.id)
                        .detailPlacement(.side)
                }
                BuildFailureCard(run: run, copier: BuildFailureCopier(buildStore: buildStore, extrasStore: extrasStore, logOpener: logOpener))
                    .id(run.id)
                    .detailPlacement(.side)
            }
            if let commit = model.commit {
                Group {
                    if columns == .two {
                        commitCard(commit)
                    } else {
                        commitQuote(commit)
                    }
                }
                .detailPlacement(.side)
            }
            RegressionGroup(run: run, buildStore: buildStore, extrasStore: extrasStore, openBuild: openBuild, compareRequest: compareRequest).id(run.id)
                .detailPlacement(.side)
            testFlightGroup
                .detailPlacement(.side)
            if columns == .two, !model.info.isEmpty {
                facts(model, columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cumulusGroup()
                    .detailPlacement(.side)
            }
            tabs(model)
                .accessibilitySortPriority(columns == .two ? 1 : 0)
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

    /// Who the build is: its app, number and state, how long it took; then the facts, or its actions when the facts
    /// have a column of their own.
    private func identityCard(_ model: BuildDetailModel, columns: DetailColumns) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // On one line when it fits; in a column too narrow for that, the capsules go under the number.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    appIcon
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            number(model)
                            // A long title is cut, it does not send the capsules under the number.
                            title(model).frame(minWidth: 40, idealWidth: 40, maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 6) { capsules(model) }
                    }
                    Spacer(minLength: 8)
                    duration(model)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        appIcon
                        VStack(alignment: .leading, spacing: 2) {
                            number(model)
                            title(model)
                        }
                        Spacer(minLength: 8)
                        duration(model)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { capsules(model) }
                        VStack(alignment: .leading, spacing: 6) { capsules(model) }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if columns == .two {
                if !model.frieze.isEmpty {
                    Divider()
                    frieze(model).padding(.top, 4)
                }
            } else if !model.info.isEmpty {
                Divider()
                facts(model, columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    @ViewBuilder
    private var appIcon: some View {
        if let product = buildStore.snapshot.product(id: run.productID) {
            AppIconView(
                name: product.displayName, swatch: palette.swatch(for: product.name), size: 44,
                artwork: icons?.artwork(of: product, in: buildStore.snapshot)
            )
        }
    }

    private func number(_ model: BuildDetailModel) -> some View {
        Text(model.numberText)
            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }

    private func title(_ model: BuildDetailModel) -> some View {
        Text(model.title)
            .font(.title3)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func capsules(_ model: BuildDetailModel) -> some View {
        CapsuleTag(text: model.statusText, systemImage: model.status.systemImage, tint: model.status.tint)
        if let reference = model.reference {
            CapsuleTag(text: reference, systemImage: "arrow.triangle.branch")
        }
        if let sha = model.shortSha {
            CapsuleTag(text: sha, isMonospaced: true)
        }
    }

    @ViewBuilder
    private func duration(_ model: BuildDetailModel) -> some View {
        if let duration = model.clockDuration {
            VStack(alignment: .trailing, spacing: 2) {
                Text(duration)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                if let age = model.age {
                    Text(age).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(model.status == .running ? "Elapsed" : "Duration"))
            .accessibilityValue(Text(UsageFormat.dotted([duration, model.age].compactMap(\.self))))
        }
    }

    private func facts(_ model: BuildDetailModel, columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(model.info) { InfoItem(key: $0.title, value: $0.value, help: $0.help) }
        }
    }

    private func frieze(_ model: BuildDetailModel) -> some View {
        ActionsFrieze(
            steps: model.frieze,
            logSteps: Set(model.frieze.filter { ($0.status == .failed || $0.status == .errored) && offersLogs($0.id) }.map(\.id)),
            busyLogSteps: Set(model.frieze.filter { logOpener?.state(of: $0.id).isBusy == true }.map(\.id)),
            openLogs: { openLogs(of: $0, model: model) }
        )
    }

    /// The failed build's earlier success, while the two are not compared yet: what “Compare with #n” would load.
    private var comparison: CIBuildRun? {
        let status = BuildStatus(run: run)
        guard run.executionProgress == .complete, status == .failed || status == .errored,
              let reference = RegressionReport.reference(for: run, in: buildStore.snapshot)
        else { return nil }
        if let extras = extrasStore.extras(for: run.id), let referenceExtras = extrasStore.extras(for: reference.id),
           RegressionReport.isReady(extras: extras, referenceExtras: referenceExtras) {
            return nil
        }
        return reference
    }

    /// The commit in its author's words, as a quotation, then the ways to it.
    private func commitQuote(_ commit: CommitInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.title3.weight(.bold))
                .foregroundStyle(CumulusStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if let message = commit.message {
                    Text(message).lineLimit(4).textSelection(.enabled)
                }
                commitWays(commit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    /// The same commit as a card of the side column: its ways go under one another when they do not fit on a line.
    private func commitCard(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit", comment: "Heading of the card that shows a build's commit")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if let message = commit.message {
                Text(message).lineLimit(6).textSelection(.enabled)
            }
            commitWays(commit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    /// Who wrote the commit and the ways to it: on one line, then under one another as the column narrows.
    private func commitWays(_ commit: CommitInfo) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                commitAuthor(commit)
                commitLinks(commit)
            }
            VStack(alignment: .leading, spacing: 6) {
                commitAuthor(commit)
                HStack(spacing: 12) { commitLinks(commit) }
            }
            VStack(alignment: .leading, spacing: 6) {
                commitAuthor(commit)
                commitLinks(commit)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func commitAuthor(_ commit: CommitInfo) -> some View {
        if let author = commit.author {
            Text(author).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func commitLinks(_ commit: CommitInfo) -> some View {
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
        if let reference = comparison, access.allows(.regressions) {
            Button("Compare with \(reference.number.map { "#\($0)" } ?? "#?")") { compareRequest += 1 }
                .buttonStyle(.link)
                .help("Loads the tests and issues of both builds, one action at a time.")
        }
    }

    @ViewBuilder
    private var testFlightGroup: some View {
        let known = extrasStore.extras(for: run.id)?.betaBuilds ?? []
        let isSkeleton = SkeletonRules.testFlightCard(
            shipsToTestFlight: buildStore.snapshot.workflow(id: run.workflowID)?.shipsToTestFlight ?? false,
            isSucceeded: run.completionStatus == .succeeded, hasBuilds: !known.isEmpty, loadEnded: betaEndedRunID == run.id
        )
        if !known.isEmpty || isSkeleton {
            VStack(alignment: .leading, spacing: 8) {
                Text("TestFlight")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .unredacted()
                ForEach(isSkeleton ? [CIBetaBuild.placeholder] : known) { build in
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
            .skeleton(isSkeleton)
        }
    }

    private func tabs(_ model: BuildDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    pill(.actions, String(localized: "Actions"), count: model.actions.count)
                    pill(.tests, String(localized: "Tests"), count: model.testFailureCount, countsFailures: true)
                    pill(.problems, String(localized: "Issues"), count: model.issueCount)
                    pill(.artifacts, String(localized: "Artifacts"), count: nil)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        pill(.actions, String(localized: "Actions"), count: model.actions.count)
                        pill(.tests, String(localized: "Tests"), count: model.testFailureCount, countsFailures: true)
                    }
                    HStack(spacing: 6) {
                        pill(.problems, String(localized: "Issues"), count: model.issueCount)
                        pill(.artifacts, String(localized: "Artifacts"), count: nil)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Details"))

            let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
            let extras = extrasStore.extras(for: run.id)
            switch tab {
            case .actions: actionsTab(model)
            case .tests:
                TestsTabView(
                    results: extras?.testsByAction ?? [:], actions: actions, state: extrasStore.state(.tests, runID: run.id),
                    insight: openInsight, retry: { Task { await extrasStore.loadTests(for: run, actions: actions) } }
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

    /// What the Tests tab may use: the groups of this build, only while the feature is open.
    private var openInsight: FailureInsightRecord? {
        guard BuildFailurePrompt.isOffered(for: run),
              FailureInsightFeature.mode(model: .current, settingOn: isInsightSettingOn, proAllows: access.allows(.failureInsight)) == .open
        else { return nil }
        return insights?.insight(for: run.id)
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

    /// One tab, as a glass pill with its counter; the one on screen is filled.
    @ViewBuilder
    private func pill(_ value: BuildTab, _ title: String, count: Int?, countsFailures: Bool = false) -> some View {
        let isSelected = tab == value
        let shown = count.flatMap { $0 > 0 ? $0 : nil }
        let label = HStack(spacing: 6) {
            Text(title).lineLimit(1).fixedSize()
            if let shown {
                Text(shown, format: .number)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(countsFailures && !isSelected ? AnyShapeStyle(BuildStatus.failed.textTint) : AnyShapeStyle(.tint))
                    .background(
                        countsFailures && !isSelected ? AnyShapeStyle(BuildStatus.failed.tint.opacity(0.16)) : AnyShapeStyle(.tint.opacity(0.16)),
                        in: .capsule
                    )
            }
        }
        let spoken = shown.map { countsFailures ? String(localized: "\($0) failed") : $0.formatted() } ?? ""
        Button { tab = value } label: { label }
            .buttonStyle(PillButtonStyle(isSelected: isSelected))
            .accessibilityValue(Text(spoken))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
