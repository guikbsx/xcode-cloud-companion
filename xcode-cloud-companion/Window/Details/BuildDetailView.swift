import SwiftUI

/// The right column: a big number, the state in capsules, the actions frieze, the facts, the commit and the detail card.
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
    /// The “Log Excerpt” card of a failed build; without it the card does not exist.
    var logExcerpts: LogExcerptStore?
    /// Reads the history of a test of this build's workflow; nil leaves the button out.
    var testHistory: WorkflowTestsModel?
    /// The latest TestFlight builds of the account's apps: with Cumulus Pro, the build's road to the testers is drawn from it.
    var testFlight: TestFlightStore?
    /// What gives the build to TestFlight groups; without it the card does not exist.
    var distribution: TestFlightDistributionAccess?

    /// Which parts of the detail card are open, and the one another screen asked to see.
    var parts = BuildPartsState()
    /// Bumped by “Compare with #n” beside the commit: the group below starts its comparison.
    @State private var compareRequest = 0
    /// The build whose TestFlight builds have been asked for, answered or not.
    @State private var betaEndedRunID: String?
    @Environment(ProAccess.self) private var access: ProAccess?
    @Environment(AppleStatusStore.self) private var appleStatus: AppleStatusStore?
    @AppStorage(FailureInsightFeature.settingKey) private var isInsightSettingOn = true

    var body: some View {
        TickingView(interval: Self.redrawInterval(for: run)) { now in
            content(now: now, BuildDetailModel(
                run: run,
                product: buildStore.snapshot.products.first { $0.id == run.productID },
                workflow: buildStore.snapshot.workflow(id: run.workflowID),
                actions: buildStore.snapshot.actionsByRunID[run.id] ?? [],
                teamID: teamID,
                now: now,
                cost: ledger.flatMap { UsageCalculator.cost(of: run, in: buildStore.snapshot, ledger: $0, now: now) },
                eta: BuildETA(run: run, among: buildStore.snapshot.runs, now: now)
            ))
        }
        .task(id: run) {
            await extrasStore.loadBetaBuilds(for: run)
            betaEndedRunID = run.id
        }
        .task(id: run.id) { await appleStatus?.sheetDidOpen(for: run) }
    }

    /// A running build's durations go on every second until a sync says it ended; a finished build only has its
    /// "2 hours ago" to keep up to date.
    nonisolated static func redrawInterval(for run: CIBuildRun) -> TimeInterval {
        run.executionProgress == .complete ? 60 : 1
    }

    private func content(now: Date, _ model: BuildDetailModel) -> some View {
        DetailScroll(
            scrollTarget: parts.request.flatMap { $0.runID == run.id ? DetailScrollTarget(id: $0.part, serial: $0.serial) : nil },
            didScroll: { parts.finish($0) }
        ) { columns in
            if let appleStatus, let event = appleStatus.event(covering: run, at: now) {
                AppleStatusBanner(
                    banner: AppleStatusFormat.banner(for: event, stoppedAt: run.finishedDate, now: now),
                    canWatch: event.isOngoing, isWatching: appleStatus.isWatching,
                    openStatusPage: { NSWorkspace.shared.open(AppleStatusSchedule.statusPage) },
                    watch: { appleStatus.startWatching(event) }
                )
                .detailPlacement(.full)
            }
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
                if let logExcerpts, let logOpener, let target = LogExcerptTarget.action(in: buildStore.snapshot.actionsByRunID[run.id] ?? []) {
                    LogExcerptSection(
                        run: run, action: target, actionName: model.actions.first { $0.id == target.id }?.name ?? target.name ?? "",
                        title: logTitle(of: target.id, model: model), store: logExcerpts, logOpener: logOpener, extras: extrasStore.extras(for: run.id)
                    )
                    .id(run.id)
                    .detailPlacement(.side)
                }
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
            testFlightDistributionGroup(now: now)
                .detailPlacement(.side)
            testFlightTimelineGroup(now: now)
                .detailPlacement(.side)
            if columns == .two, !model.info.isEmpty {
                facts(model, columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cumulusGroup()
                    .detailPlacement(.side)
            }
            detailCard(model)
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
            if let estimatedEnd = model.estimatedEnd {
                Label(estimatedEnd, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(model.spokenEstimatedEnd ?? estimatedEnd))
            }
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

    /// “From the commit to the testers”, for a build that was handed to TestFlight and that the store has read.
    @ViewBuilder
    private func testFlightTimelineGroup(now: Date) -> some View {
        if access.allows(.testFlightTracking), run.completionStatus == .succeeded, let testFlight,
           let known = extrasStore.extras(for: run.id)?.betaBuilds?.lazy.compactMap({ testFlight.lookup(buildID: $0.id) }).first {
            let archive = (buildStore.snapshot.actionsByRunID[run.id] ?? []).first { $0.actionType == .archive && $0.completionStatus == .succeeded }
            TestFlightTimelineCard(
                timeline: TestFlightTimeline.make(
                    build: known.build, observation: known.observation, archiveFinished: archive?.finishedDate ?? run.finishedDate, now: now
                ),
                buildLabel: known.build.label
            )
        }
    }

    /// The build's TestFlight build that the store has read, and the app it belongs to: what the card of groups is made from.
    private var distributable: (build: TestFlightBuild, appID: String)? {
        guard run.completionStatus == .succeeded, buildStore.snapshot.workflow(id: run.workflowID)?.shipsToTestFlight == true, let testFlight,
              let known = extrasStore.extras(for: run.id)?.betaBuilds?.lazy.compactMap({ testFlight.lookup(buildID: $0.id) }).first,
              let appID = testFlight.appID(ofBuild: known.build.id)
        else { return nil }
        return (known.build, appID)
    }

    /// Whether the card of groups stands in place of the plain TestFlight card: Cumulus Pro, a build the store has read, and
    /// groups to show or still on their way.
    private var showsDistribution: Bool {
        guard access.allows(.testFlightDistribution), let distribution, let distributable else { return false }
        let groups = distribution.groups
        return !(groups.groups(for: distributable.appID) ?? []).isEmpty || !groups.hasAttempted(distributable.appID)
    }

    /// Giving the build to groups: the card, or the way to Pro where it would be.
    @ViewBuilder
    private func testFlightDistributionGroup(now: Date) -> some View {
        if showsDistribution, let distribution, let distributable {
            TestFlightDistributionCard(
                build: distributable.build, appID: distributable.appID,
                appName: buildStore.snapshot.product(id: run.productID)?.displayName, access: distribution,
                teamID: teamID, now: now
            )
            .id(run.id)
        } else if !access.allows(.testFlightDistribution), run.completionStatus == .succeeded,
                  buildStore.snapshot.workflow(id: run.workflowID)?.shipsToTestFlight == true,
                  !(extrasStore.extras(for: run.id)?.betaBuilds ?? []).isEmpty {
            ProLockedCard(feature: .testFlightDistribution)
        }
    }

    @ViewBuilder
    private var testFlightGroup: some View {
        let known = extrasStore.extras(for: run.id)?.betaBuilds ?? []
        let isSkeleton = SkeletonRules.testFlightCard(
            shipsToTestFlight: buildStore.snapshot.workflow(id: run.workflowID)?.shipsToTestFlight ?? false,
            isSucceeded: run.completionStatus == .succeeded, hasBuilds: !known.isEmpty, loadEnded: betaEndedRunID == run.id
        )
        if (!known.isEmpty && !showsDistribution) || isSkeleton {
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

    /// The build's problems, tests, actions and artifacts one under another, the cause first.
    private func detailCard(_ model: BuildDetailModel) -> some View {
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        let extras = extrasStore.extras(for: run.id)
        let category = insights?.insight(for: run.id)?.category ?? BuildSheetOrder.Facts.category(of: run, actions: actions, extras: extras)
        return BuildPartsCard(
            run: run,
            facts: BuildSheetOrder.Facts(run: run, actions: actions, workflow: buildStore.snapshot.workflow(id: run.workflowID), category: category, extras: extras),
            state: parts,
            counter: { counter(of: $0, model: model) },
            load: { await load($0) }
        ) { part in
            partContent(part, model)
        }
        .id(run.id)
    }

    private func counter(of part: BuildPart, model: BuildDetailModel) -> BuildPartCounter {
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        let extras = extrasStore.extras(for: run.id)
        let isRunning = model.status == .running
        switch part {
        case .tests:
            return .tests(
                isRunning: isRunning, counts: run.issueCounts,
                results: extras?.testsComplete == true ? actions.flatMap { extras?.testsByAction[$0.id] ?? [] } : nil
            )
        case .problems:
            return .problems(isRunning: isRunning, isFailedBuild: model.status == .failed || model.status == .errored, counts: run.issueCounts)
        case .actions:
            return .actions(
                count: model.actions.count, launched: model.actions.filter { $0.duration != nil }.count,
                finished: actions.filter { $0.executionProgress == .complete }.count, isRunning: isRunning, clock: model.clockDuration
            )
        case .artifacts:
            return .artifacts(isRunning: isRunning, artifacts: extras?.artifactsComplete == true ? actions.flatMap { extras?.artifactsByAction[$0.id] ?? [] } : nil)
        }
    }

    /// Reads what an open part shows; a closed one never gets here.
    private func load(_ part: BuildPart) async {
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        switch part {
        case .tests: await extrasStore.loadTests(for: run, actions: actions)
        case .problems: await extrasStore.loadIssues(for: run, actions: actions)
        case .artifacts: await extrasStore.loadArtifacts(for: run, actions: actions)
        case .actions: break
        }
    }

    @ViewBuilder
    private func partContent(_ part: BuildPart, _ model: BuildDetailModel) -> some View {
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        let extras = extrasStore.extras(for: run.id)
        switch part {
        case .actions: actionsPart(model)
        case .tests:
            TestsPartView(
                results: extras?.testsByAction ?? [:], actions: actions, state: extrasStore.state(.tests, runID: run.id),
                insight: openInsight, history: historyAccess, retry: { Task { await extrasStore.loadTests(for: run, actions: actions) } }
            )
        case .problems:
            IssuesPartView(
                issues: extras?.issuesByAction ?? [:], actions: actions, state: extrasStore.state(.issues, runID: run.id),
                retry: { Task { await extrasStore.loadIssues(for: run, actions: actions) } }
            )
        case .artifacts:
            ArtifactsPartView(
                artifacts: extras?.artifactsByAction ?? [:], actions: actions, state: extrasStore.state(.artifacts, runID: run.id), saver: artifactSaver,
                retry: { Task { await extrasStore.loadArtifacts(for: run, actions: actions) } }
            )
        }
    }

    private var historyAccess: TestHistoryAccess? {
        guard let testHistory, let workflowID = run.workflowID else { return nil }
        return TestHistoryAccess(workflowID: workflowID, tests: testHistory, openBuild: { id in
            parts.show(.tests, ofRun: id)
            openBuild(id)
        })
    }

    /// What the Tests part may use: the groups of this build, only while the feature is open.
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

    private func logTitle(of actionID: String, model: BuildDetailModel) -> String {
        let name = model.actions.first { $0.id == actionID }?.name ?? ""
        return [[model.appName, model.numberText].compactMap(\.self).joined(separator: " "), name].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    private func openLogs(of actionID: String, model: BuildDetailModel) {
        guard let action = action(actionID) else { return }
        logOpener?.start(action, run: run, knownArtifacts: knownArtifacts(of: actionID), title: logTitle(of: actionID, model: model))
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

    private func actionsPart(_ model: BuildDetailModel) -> some View {
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
                    } else if model.status != .running {
                        Text("not launched").font(.caption).foregroundStyle(.secondary)
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
    }
}
