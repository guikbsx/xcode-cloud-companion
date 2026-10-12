import SwiftUI

/// The window shows one account at a time, the selected one; with several, the toolbar names it and switches.
struct MainWindowRoot: View {
    let accounts: AccountsModel
    let navigation: NavigationModel
    let pins: PinnedWorkflows
    let openSettings: () -> Void

    var body: some View {
        Group {
            if let session = accounts.selected {
                MainWindowView(
                    session: session, others: accounts.sessions.filter { $0.id != session.id }, navigation: navigation, pins: pins,
                    openSettings: openSettings, importUsageExport: { await accounts.importUsageExport(at: $0) }
                )
                // Sheets, tasks and what was typed belong to the account they were opened for.
                .id(session.id)
            } else {
                NotSetUpView(openSettings: openSettings)
            }
        }
        .toolbar {
            if accounts.hasSeveral {
                ToolbarItem(placement: .navigation) {
                    Picker("Account", selection: Binding(get: { accounts.selectedID }, set: { if let id = $0 { accounts.select(id) } })) {
                        ForEach(accounts.sessions) { session in
                            Text(session.name).tag(Optional(session.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Switch to another App Store Connect account")
                }
            }
        }
    }
}

/// The three columns: sidebar, builds, detail. The columns are filled in by their own tickets; this is the frame.
struct MainWindowView: View {
    let session: AccountSession
    /// The other accounts: what they already hold decides whether the window may wait, and their first fetch shows in the sidebar.
    var others: [AccountSession] = []
    @Bindable var navigation: NavigationModel
    @Bindable var pins: PinnedWorkflows
    let openSettings: () -> Void
    let importUsageExport: (URL) async -> Void
    @State private var launchTarget: LaunchTarget?
    @State private var pauseTarget: WorkflowPauseTarget?
    @State private var editTarget: WorkflowEditTarget?

    private var buildStore: BuildStore { session.buildStore }
    private var usageStore: UsageStore { session.usageStore }
    private var settings: SettingsModel { session.settings }
    private var extrasStore: BuildExtrasStore { session.extrasStore }
    private var workflowStore: WorkflowDetailStore { session.windowStores.workflowStore }
    private var artifactSaver: ArtifactSaver { session.windowStores.artifactSaver }
    private var launcher: BuildLauncher { session.windowStores.launcher }
    private var icons: AppIconStore { session.windowStores.icons }
    private var logOpener: LogOpener { session.windowStores.logOpener }
    private var workflowTests: WorkflowTestsModel { session.windowStores.workflowTests }
    private var pauser: WorkflowPauser { session.windowStores.pauser }
    private var palette: AppPalette { session.paletteStore.refreshed(for: buildStore.snapshot, summary: usageSummary) }

    var body: some View {
        switch contentState {
        case .ready:
            columns
        case .loading(let step):
            FirstFetchView(step: step)
        case .failed(let message, let isRetrying):
            FirstFetchFailedView(message: message, isRetrying: isRetrying, retry: { Task { await buildStore.refreshNow() } }, openSettings: openSettings)
        case .notSetUp:
            NotSetUpView(openSettings: openSettings)
        }
    }

    private var contentState: WindowContentState {
        .of(
            isConfigured: buildStore.isConfigured, hasAttemptedSync: buildStore.hasAttemptedSync, isSyncing: buildStore.isSyncing,
            hasContent: buildStore.snapshot.hasContent, anotherAccountHasContent: others.contains { $0.buildStore.snapshot.hasContent },
            errorMessage: buildStore.lastErrorMessage, step: buildStore.progress
        )
    }

    private var columns: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            Group {
                if navigation.sidebarSelection == .references, navigation.referenceScope == nil {
                    ReferencesListView(
                        buildStore: buildStore, store: session.windowStores.references, open: { navigation.referenceScope = $0 },
                        icons: icons, palette: palette
                    )
                } else {
                    BuildListView(
                        buildStore: buildStore, navigation: navigation,
                        scope: navigation.referenceScope.map(BuildListScope.reference) ?? BuildListScope(navigation.sidebarSelection),
                        back: navigation.referenceScope == nil ? nil : { navigation.referenceScope = nil },
                        older: session.windowStores.older, icons: icons, palette: palette
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            detail
        }
        .toolbar {
            if let target = launchTargetForToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { launchTarget = target } label: { LaunchButtonLabel() }
                        .buttonStyle(.glassProminent)
                        .help("Launch this workflow")
                }
            }
        }
        .sheet(item: $launchTarget) { target in
            LaunchSheet(
                target: target, launcher: launcher,
                onStarted: { run in
                    buildStore.insertStarted(run)
                    navigation.showBuild(run.id)
                },
                onNotAllowed: { settings.keyAccess = .readOnly }
            )
        }
        .sheet(item: $pauseTarget) { target in
            WorkflowPauseSheet(target: target, pauser: pauser, onNotAllowed: { settings.keyAccess = .readOnly })
        }
        .sheet(item: $editTarget) { target in
            WorkflowEditSheet(target: target, editor: session.windowStores.editor, onSaved: { _ in }, onNotAllowed: { settings.keyAccess = .readOnly })
        }
        .task(id: buildStore.snapshot.appIcons) { await icons.load(buildStore.snapshot.appIcons) }
        .task {
            // The detail views spend requests too: the budget shown follows what the client last saw.
            while !Task.isCancelled {
                await buildStore.updateRateLimit()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var usageSummary: UsageSummary? {
        session.usageSummary(now: Date())
    }

    /// The scheduled workflows: the sync's entry, or the richer one read for the workflow's sheet.
    private var forecast: ScheduleForecast {
        let snapshot = buildStore.snapshot
        let summary = usageSummary
        return ScheduleForecast(
            workflows: snapshot.workflows.map { workflowStore.workflow(id: $0.id) ?? $0 }, products: snapshot.products,
            cycleEnd: summary?.cycle.end, usage: summary?.byWorkflow ?? [], now: Date()
        )
    }

    private var sidebar: some View {
        let summary = usageSummary
        return SidebarView(
            content: SidebarContent(snapshot: buildStore.snapshot, pinnedIDs: pins.ids, palette: session.paletteStore.refreshed(for: buildStore.snapshot, summary: summary)),
            pins: pins,
            selection: $navigation.sidebarSelection,
            cycle: CycleCard.Content(summary: summary),
            setPlan: settings.plan == nil ? openSettings : nil,
            activity: session.activity(now: Date()),
            backgroundActivity: SyncActivity.background(among: others.map { ($0.name, $0.activity(now: Date())) }),
            budgetText: buildStore.rateLimit.map {
                String(localized: "\($0.remaining) req.", comment: "Foot of the sidebar: App Store Connect API requests left this hour. A few characters: the tooltip says it in full.")
            },
            budgetHelp: buildStore.rateLimit.map { String(localized: "\($0.remaining) of \($0.limit) requests left this hour") },
            artwork: icons.artwork(in: buildStore.snapshot, by: \.id),
            togglePause: canLaunch ? { askToTogglePause(workflowID: $0.id) } : nil
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let run = buildStore.snapshot.runs.first(where: { $0.id == navigation.selectedBuildID }) {
            BuildDetailView(
                run: run, buildStore: buildStore, extrasStore: extrasStore, artifactSaver: artifactSaver, onRebuild: rebuildAction(for: run),
                teamID: settings.issuerID.isEmpty ? nil : settings.issuerID,
                icons: icons, palette: palette,
                openBuild: { navigation.selectedBuildID = $0 }, logOpener: logOpener, ledger: usageStore.ledger, tab: $navigation.buildTab
            )
            .environment(\.sourceOpening, sourceOpening(for: run))
        } else if navigation.sidebarSelection == .overview {
            OverviewView(
                summary: usageSummary, palette: palette, usage: usageStore,
                openSettings: openSettings,
                openUsagePage: { NSWorkspace.shared.open(AppStoreConnectLinks.xcodeCloudUsage(teamID: settings.issuerID)) },
                importExport: importUsageExport,
                displayNames: buildStore.snapshot.displayNames, artwork: icons.artwork(in: buildStore.snapshot, by: \.name),
                breakdown: { row in
                    settings.plan.map {
                        WorkflowCostBreakdown(
                            product: row.productKey, workflow: row.workflow, snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: Date()
                        )
                    }
                },
                forecast: forecast,
                openWorkflow: { navigation.sidebarSelection = .workflow($0) }
            )
        } else if case .workflow(let id) = navigation.sidebarSelection, let workflow = workflowStore.workflow(id: id) ?? buildStore.snapshot.workflow(id: id) {
            let product = buildStore.snapshot.products.first { $0.id == workflow.productID }
            WorkflowDetailView(
                model: WorkflowDetailModel(workflow: workflow, productName: product?.displayName), tests: workflowTests,
                openBuildTests: { id in
                    // The build stays in its workflow's list: only the sheet and its tab change.
                    navigation.buildTab = .tests
                    navigation.selectedBuildID = id
                },
                trends: WorkflowTrends(runs: buildStore.snapshot.runs.filter { $0.workflowID == id }),
                openBuild: { navigation.selectedBuildID = $0 },
                togglePause: canLaunch ? { askToTogglePause(workflowID: id) } : nil,
                xcodeWarning: XcodeVersionCheck.warning(
                    version: workflow.xcodeVersion ?? buildStore.snapshot.workflow(id: id)?.xcodeVersion, name: workflow.xcodeVersionName,
                    among: buildStore.snapshot.xcodeVersions
                ),
                editWorkflow: canLaunch && workflow.isLockedForEditing != true ? { editTarget = WorkflowEditTarget(workflow: workflow) } : nil,
                workflowURL: AppStoreConnectLinks.workflow(appID: product?.appID, workflowID: id, teamID: settings.issuerID.isEmpty ? nil : settings.issuerID)
            )
                .task(id: id) { await loadWorkflow(id) }
        } else {
            ContentUnavailableView("Select a build", systemImage: "cloud")
        }
    }

    private var canLaunch: Bool {
        settings.keyAccess == .canLaunch
    }

    /// Opens a build's files in Xcode from the app's local clone.
    private func sourceOpening(for run: CIBuildRun) -> SourceOpening {
        let product = buildStore.snapshot.products.first { $0.id == run.productID }
        let opener = SourceOpener(repositories: session.localRepositories, product: product?.name ?? run.productID, appName: product?.displayName ?? run.productID)
        return SourceOpening { path, line in opener.open(path: path, line: line) }
    }

    /// The workflow of the build on screen, or the one picked in the sidebar.
    private var currentWorkflow: (workflow: CIWorkflow, productID: String, run: CIBuildRun?)? {
        let snapshot = buildStore.snapshot
        let run = snapshot.runs.first { $0.id == navigation.selectedBuildID }
        let workflowID: String? = run?.workflowID ?? { if case .workflow(let id) = navigation.sidebarSelection { id } else { nil } }()
        guard let workflowID else { return nil }
        let workflow = workflowStore.workflow(id: workflowID) ?? snapshot.workflow(id: workflowID)
        guard let workflow, let productID = workflow.productID ?? run?.productID ?? snapshot.runs.first(where: { $0.workflowID == workflowID })?.productID else { return nil }
        return (workflow, productID, run)
    }

    private var launchTargetForToolbar: LaunchTarget? {
        guard canLaunch, let current = currentWorkflow else { return nil }
        let preferred = current.run?.sourceBranchOrTag
            ?? buildStore.snapshot.runs.first { $0.workflowID == current.workflow.id }?.sourceBranchOrTag
        return LaunchTarget(
            mode: .launch(current.workflow, preferredReference: preferred), productID: current.productID,
            recentRuns: buildStore.snapshot.runs.filter { $0.workflowID == current.workflow.id }
        )
    }

    private func rebuildAction(for run: CIBuildRun) -> (() -> Void)? {
        guard canLaunch, run.executionProgress == .complete, let current = currentWorkflow else { return nil }
        return { launchTarget = LaunchTarget(mode: .rebuild(run, current.workflow), productID: current.productID) }
    }

    /// Opens the confirmation for the opposite of the workflow's state, as far as it is known.
    private func askToTogglePause(workflowID: String) {
        guard let workflow = workflowStore.workflow(id: workflowID) ?? buildStore.snapshot.workflow(id: workflowID),
              let isEnabled = workflow.isEnabled, workflow.isLockedForEditing != true
        else { return }
        pauseTarget = WorkflowPauseTarget(workflow: workflow, enable: !isEnabled)
    }

    private func loadWorkflow(_ id: String) async {
        let snapshot = buildStore.snapshot
        let productID = snapshot.workflow(id: id)?.productID ?? snapshot.runs.first { $0.workflowID == id }?.productID
        if let productID { await workflowStore.load(productID: productID) }
    }
}

/// No account, or one whose key is missing: the way to Settings.
private struct NotSetUpView: View {
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Cumulus isn’t set up yet", systemImage: "key")
        } description: {
            Text("Add your App Store Connect API key to see your Xcode Cloud builds here.")
        } actions: {
            Button("Configure Cumulus…", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The very first fetch of an account: nothing to show yet, so the window says what it is reading.
private struct FirstFetchView: View {
    let step: String?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Fetching your Xcode Cloud builds")
            } icon: {
                ProgressView()
                    .controlSize(.large)
            }
        } description: {
            Text(step ?? String(localized: "Listing your apps and their builds…"))
        }
    }
}

/// The first fetch failed: the reason, and the two ways out.
private struct FirstFetchFailedView: View {
    let message: String
    let isRetrying: Bool
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t fetch your builds", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
            Button("Settings…", action: openSettings)
            if isRetrying {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
