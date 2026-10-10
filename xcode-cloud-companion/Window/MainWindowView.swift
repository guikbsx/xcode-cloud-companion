import SwiftUI

/// The three columns: sidebar, builds, detail. The columns are filled in by their own tickets; this is the frame.
struct MainWindowView: View {
    let buildStore: BuildStore
    let usageStore: UsageStore
    let settings: SettingsModel
    let extrasStore: BuildExtrasStore
    let workflowStore: WorkflowDetailStore
    let artifactOpener: ArtifactOpener
    let launcher: BuildLauncher
    @Bindable var navigation: NavigationModel
    @Bindable var pins: PinnedWorkflows
    let openSettings: () -> Void
    @AppStorage(KeyAccess.defaultsKey) private var keyAccess = KeyAccess.readOnly.rawValue
    @State private var launchTarget: LaunchTarget?

    var body: some View {
        if buildStore.isConfigured {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                BuildListView(buildStore: buildStore, navigation: navigation)
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
                    onNotAllowed: { keyAccess = KeyAccess.readOnly.rawValue }
                )
            }
            .task {
                // The detail views spend requests too: the budget shown follows what the client last saw.
                while !Task.isCancelled {
                    await buildStore.updateRateLimit()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } else {
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

    private var usageSummary: UsageSummary? {
        settings.plan.map {
            UsageCalculator.summary(snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: Date())
        }
    }

    private var sidebar: some View {
        let summary = usageSummary
        return SidebarView(
            content: SidebarContent(snapshot: buildStore.snapshot, pinnedIDs: pins.ids, palette: AppPaletteStore().refreshed(for: buildStore.snapshot, summary: summary)),
            pins: pins,
            selection: $navigation.sidebarSelection,
            cycle: CycleCard.Content(summary: summary),
            budgetText: buildStore.rateLimit.map { String(localized: "\($0.remaining) of \($0.limit) requests left this hour") }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let run = buildStore.snapshot.runs.first(where: { $0.id == navigation.selectedBuildID }) {
            BuildDetailView(
                run: run, buildStore: buildStore, extrasStore: extrasStore, artifactOpener: artifactOpener, onRebuild: rebuildAction(for: run),
                teamID: settings.issuerID.isEmpty ? nil : settings.issuerID
            )
        } else if navigation.sidebarSelection == .overview {
            OverviewView(
                summary: usageSummary, palette: AppPaletteStore().refreshed(for: buildStore.snapshot, summary: usageSummary), usage: usageStore,
                openSettings: openSettings,
                openUsagePage: { NSWorkspace.shared.open(AppStoreConnectLinks.xcodeCloudUsage(teamID: settings.issuerID)) }
            )
        } else if case .workflow(let id) = navigation.sidebarSelection, let workflow = workflowStore.workflow(id: id) ?? buildStore.snapshot.workflow(id: id) {
            let product = buildStore.snapshot.products.first { $0.id == workflow.productID }
            WorkflowDetailView(model: WorkflowDetailModel(workflow: workflow, productName: product?.name))
                .task(id: id) { await loadWorkflow(id) }
        } else {
            ContentUnavailableView("Select a build", systemImage: "cloud")
        }
    }

    private var canLaunch: Bool {
        KeyAccess(rawValue: keyAccess) == .canLaunch
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
        return LaunchTarget(mode: .launch(current.workflow, preferredReference: preferred), productID: current.productID)
    }

    private func rebuildAction(for run: CIBuildRun) -> (() -> Void)? {
        guard canLaunch, run.executionProgress == .complete, let current = currentWorkflow else { return nil }
        return { launchTarget = LaunchTarget(mode: .rebuild(run, current.workflow), productID: current.productID) }
    }

    private func loadWorkflow(_ id: String) async {
        let snapshot = buildStore.snapshot
        let productID = snapshot.workflow(id: id)?.productID ?? snapshot.runs.first { $0.workflowID == id }?.productID
        if let productID { await workflowStore.load(productID: productID) }
    }
}
