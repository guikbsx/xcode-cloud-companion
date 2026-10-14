import Foundation

/// What the window needs to show one account beyond its builds: workflow details, launches, downloads, logs. Each
/// asks Apple with the account's own key and keeps its files in the account's own folders.
final class AccountWindowStores {
    let workflowStore: WorkflowDetailStore
    let artifactSaver: ArtifactSaver
    let launcher: BuildLauncher
    let icons: AppIconStore
    let logOpener: LogOpener
    let logExcerpts: LogExcerptStore
    let workflowTests: WorkflowTestsModel
    let pauser: WorkflowPauser
    let references: ReferencesStore
    let editor: WorkflowEditor
    let older: OlderBuildsStore

    /// `pro` is Cumulus Pro; without one (tests) every store is open.
    init(buildStore: BuildStore, extrasStore: BuildExtrasStore, paths: AccountPaths, pro: ProStore? = nil) {
        let allows: @MainActor (ProFeature) -> Bool = { [pro] in pro?.allows($0) ?? true }
        let client: () async -> AppStoreConnectClient? = { [buildStore] in await buildStore.detailClient() }
        let budget: () async -> RateLimit? = { [buildStore] in
            await buildStore.updateRateLimit()
            return buildStore.rateLimit
        }
        references = ReferencesStore(client: client, budget: budget)
        older = OlderBuildsStore(client: client, budget: budget, allowed: { allows(.olderBuilds) })
        let workflowStore = WorkflowDetailStore(cache: WorkflowDetailsCache(directory: paths.workflowDetails), client: client)
        self.workflowStore = workflowStore
        artifactSaver = ArtifactSaver(client: client)
        launcher = BuildLauncher(client: client)
        icons = AppIconStore(cache: AppIconCache(directory: paths.appIcons))
        let logOpener = LogOpener(client: client, cache: LogCache(directory: paths.logs))
        self.logOpener = logOpener
        logExcerpts = LogExcerptStore(logOpener: logOpener, budget: budget, allowed: { allows(.logExcerpt) })
        workflowTests = WorkflowTestsModel(
            reader: TestHealthReader(cache: BuildExtrasCache(directory: paths.buildDetails)),
            snapshot: { [buildStore] in buildStore.snapshot },
            loadTests: { [extrasStore] run, actions in
                await extrasStore.loadTests(for: run, actions: actions)
                if case .failed(let message, _, _) = extrasStore.state(.tests, runID: run.id) { return message }
                return nil
            },
            budget: { [buildStore] in
                await buildStore.updateRateLimit()
                return buildStore.rateLimit
            },
            allowed: { allows(.testHealth) }
        )
        pauser = WorkflowPauser(
            client: client,
            applied: { [workflowStore, buildStore] workflowID, isEnabled in
                await workflowStore.setEnabled(isEnabled, workflowID: workflowID)
                await buildStore.setWorkflowEnabled(isEnabled, workflowID: workflowID)
            },
            allowed: { allows(.pauseWorkflow) }
        )
        editor = WorkflowEditor(
            client: client,
            budget: { [buildStore] in
                await buildStore.updateRateLimit()
                return buildStore.rateLimit
            },
            applied: { [workflowStore, buildStore] workflow in
                await workflowStore.apply(workflow)
                await buildStore.applyWorkflow(workflow)
            },
            allowed: { allows(.editWorkflow) }
        )
    }
}
