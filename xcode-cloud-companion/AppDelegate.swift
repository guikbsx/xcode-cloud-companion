import AppKit
import UniformTypeIdentifiers
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unit tests run inside this app: they must not reach App Store Connect with the user's real key, nor move the user's data.
    private static let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let accounts = AccountsModel(migration: isUnderTest ? nil : AccountMigration(legacySupport: .applicationSupportDirectory))
    private let loginItemModel = LoginItemModel()
    private let pro: ProStore = {
        #if DEBUG
        // XCC_PRO=0|1|trial|lifetime|expired pins Cumulus Pro, to look at the locks and the screens without buying.
        if let forced = ProStore.forcedEntitlement(named: ProcessInfo.processInfo.environment["XCC_PRO"], now: Date()) {
            return ProStore(forced: forced)
        }
        #endif
        return ProStore()
    }()
    private let notificationPreferences = NotificationPreferences()
    /// Nil under tests: nothing is written for the widgets then.
    private var widgetFeed: WidgetFeedWriter?
    private lazy var proPurchase = ProPurchasePresenter(store: pro)
    private lazy var notifications = NotificationCoordinator(preferences: notificationPreferences, pro: pro)
    private lazy var agentLaunches = AgentLaunchService(accounts: accounts, preferences: notificationPreferences, notify: { [notifications] in await notifications.deliver($0) })
    private var notificationResponder: NotificationResponder?
    private lazy var settingsWindowController = SettingsWindowController(
        accounts: accounts, loginItem: loginItemModel, notificationPreferences: notificationPreferences, notifications: notifications,
        pro: pro, purchase: proPurchase
    )
    private let navigation = NavigationModel()
    private lazy var mainWindowController = MainWindowController(
        accounts: accounts,
        navigation: navigation,
        activation: ActivationPolicyCoordinator(app: NSApp),
        openSettings: { [weak self] in self?.openSettings() },
        pro: pro, purchase: proPurchase
    )
    private var statusItemController: StatusItemController?
    private var ipcServer: IPCSocketServer?
    private var ipcIsListening = false
    #if DEBUG
    private lazy var diagnosticWindowController = UsageDiagnosticWindowController(accounts: accounts)
    #endif

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The main menu is only seen while the main window is open, but its key equivalents drive ⌘, and copy/paste in text fields at any time.
        NSApp.mainMenu = MainMenu.make(target: self, MainMenu.Actions(
            openSettings: #selector(openSettings),
            openPro: #selector(openCumulusPro),
            openMainWindow: #selector(openMainWindow),
            refresh: #selector(refresh),
            openHelp: #selector(openHelp)
        ))
        accounts.pro = pro
        accounts.onPausedSelection = { [weak self] in self?.presentCumulusPro(for: .multipleAccounts) }
        statusItemController = StatusItemController(accounts: accounts, actions: menuActions())
        accounts.onSelectionChange = { [weak self, navigation] in
            navigation.accountDidChange()
            self?.updateWidgets()
        }

        guard !Self.isUnderTest else { return }
        widgetFeed = WidgetFeedWriter()
        // The `cumulus` command cannot ask StoreKit: the app tells it, at launch and whenever the answer changes.
        pro.onRead = { entitlement in ProStatusStore().record(isActive: entitlement.isActive, now: Date()) }
        pro.start()
        startNotifications()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(self, selector: #selector(screenDidLock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributedCenter.addObserver(self, selector: #selector(screenDidUnlock), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        // Started before the window may open: the caches are moved into their account before anything reads them.
        accounts.start()
        updateWidgets()
        Task {
            await accounts.whenReady()
            await startIPCServer()
        }
        #if DEBUG
        // Run from Xcode, the app shows its window and its menu bar at once; a Release stays in the menu bar until asked.
        openMainWindow()
        // XCC_APP=<product name> opens the window on that app's overview, to look at it without a click.
        if let name = ProcessInfo.processInfo.environment["XCC_APP"] {
            Task { [accounts, navigation] in
                await accounts.whenReady()
                for _ in 0..<40 {
                    if let product = accounts.selected?.buildStore.snapshot.products.first(where: { $0.name == name || $0.displayName == name }) {
                        navigation.sidebarSelection = .product(product.id)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        // XCC_SETTINGS=general|notifications|agents|pro|accounts opens Settings on that pane, to look at it without a click.
        if let pane = ProcessInfo.processInfo.environment["XCC_SETTINGS"].flatMap(SettingsNavigationModel.Pane.init(rawValue:)) {
            settingsWindowController.show(pane: pane)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The socket file goes with the instance that answers on it, never with another one's.
        if ipcIsListening, let path = SharedContainer.socketPath {
            unlink(path)
        }
    }

    /// Lets the `cumulus` command ask for a sync, a build's details or its sheet. A second instance leaves the first one's socket alone.
    private func startIPCServer() async {
        guard ipcServer == nil, let path = SharedContainer.socketPath else { return }
        let accounts = accounts
        let service = AppIPCService(
            sync: { id in
                guard let id else { return accounts.selected?.buildStore }
                // A paused account is not synced on anyone's request.
                return accounts.session(id: id).flatMap { accounts.isPaused($0) ? nil : $0.buildStore }
            },
            openBuild: { [weak self] id in
                self?.openBuild(id)
                NSApp.activate()
            },
            loadBuildDetails: { id in
                guard let owner = await accounts.owner(ofBuild: id) else { return false }
                return await BuildDetailsLoader(buildStore: owner.buildStore, extrasStore: owner.extrasStore).load(id)
            },
            launchBuild: { [agentLaunches] request in await agentLaunches.launch(request) }
        )
        let dispatcher = IPCDispatcher(service: service)
        let server = IPCSocketServer(path: path) { await dispatcher.reply(to: $0) }
        guard (try? await server.start()) != nil else { return }
        ipcServer = server
        ipcIsListening = true
    }

    /// The widgets show the account on screen: its file is written again when that account, or its data, changes.
    private func updateWidgets() {
        guard let widgetFeed else { return }
        Task { [accounts] in
            await accounts.whenReady()
            await widgetFeed.update(for: accounts.selected)
        }
    }

    /// Banners come from what each sync changed. The delegate is in place at launch, so a click on a banner that
    /// starts the app still opens its build; the permission itself is only asked when a first banner is due.
    private func startNotifications() {
        let responder = NotificationResponder { [weak self] url in self?.open(url) }
        UNUserNotificationCenter.current().delegate = responder
        notificationResponder = responder
        // Every account speaks, whichever one is on screen; with several, a banner names its account.
        accounts.onSync = { [weak self] session, previous, current in
            guard let self else { return }
            updateWidgets()
            let account = NotificationAccount(id: session.id, name: accounts.hasSeveral ? session.name : nil)
            // The same figure as the menu and the Overview; nil while no reset date is set.
            let summary = session.usageSummary(now: Date())
            let notifications = notifications
            let insights = StoreFailureInsightSource(store: session.failureInsights)
            #if DEBUG
            // XCC_NOTIFY=1 posts a sample banner about the newest build after the first sync, to try the permission and the click without waiting for a build.
            let postsSample = ProcessInfo.processInfo.environment["XCC_NOTIFY"] != nil && !hasPostedSample
            if postsSample { hasPostedSample = true }
            #endif
            Task {
                await notifications.buildsDidSync(account: account, previous: previous, current: current, summary: summary, insights: insights)
                #if DEBUG
                guard postsSample, let run = current.runs.first else { return }
                await notifications.deliver([LocalNotification(
                    id: "sample", title: "Sample notification", subtitle: account.name, body: "Click to open build #\(run.number ?? 0).",
                    url: CumulusURL.build(id: run.id)
                )])
                #endif
            }
        }
    }

    #if DEBUG
    private var hasPostedSample = false
    #endif

    /// Opens what a `cumulus://` address names, in the account it belongs to: a build is looked up in every account.
    private func open(_ url: URL) {
        guard let destination = CumulusURL.destination(of: url) else { return }
        Task {
            switch destination {
            case .build(let id):
                if let owner = await accounts.owner(ofBuild: id) {
                    accounts.select(owner.id)
                }
            case .overview(let accountID):
                if let accountID {
                    await accounts.whenReady()
                    accounts.select(accountID)
                }
            case .references:
                break
            }
            navigation.open(url)
            mainWindowController.show()
            NSApp.activate()
        }
    }

    @objc func openSettings() {
        settingsWindowController.show()
    }

    @objc func openMainWindow() {
        mainWindowController.show()
    }

    /// The purchase sheet hangs on the main window: it opens the window first.
    @objc func openCumulusPro() {
        presentCumulusPro(for: nil)
    }

    /// `feature` is the locked function one came from: its benefit is read first.
    private func presentCumulusPro(for feature: ProFeature?) {
        mainWindowController.show()
        NSApp.activate()
        guard let window = mainWindowController.window else { return }
        proPurchase.present(over: window, origin: feature)
    }

    /// A first account is free; without Cumulus Pro, one more leads to the purchase sheet before any key is asked for.
    private func addAccount() {
        if accounts.canAddAccount {
            settingsWindowController.show(addingAccount: true)
        } else {
            presentCumulusPro(for: .multipleAccounts)
        }
    }

    @objc private func refresh() {
        accounts.refreshAll()
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/documentation/xcode/xcode-cloud")!)
    }

    /// A build of the account on screen opens at once; one of another account brings its account with it.
    func openBuild(_ id: String) {
        guard accounts.selected?.owns(buildRunID: id) != true, let url = CumulusURL.build(id: id) else {
            navigation.showBuild(id)
            mainWindowController.show()
            return
        }
        open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            open(url)
        }
    }

    private func menuActions() -> StatusMenuActions {
        var actions = StatusMenuActions(
            refresh: { [weak self] in self?.refresh() },
            openUsagePage: { [accounts] in
                NSWorkspace.shared.open(AppStoreConnectLinks.xcodeCloudUsage(teamID: accounts.selected?.settings.issuerID ?? ""))
            },
            importUsageExport: { [weak self] in self?.importUsageExport() },
            openSettings: { [weak self] in self?.openSettings() },
            addAccount: { [weak self] in self?.addAccount() },
            openApp: { [weak self] in self?.openMainWindow() },
            openBuild: { [weak self] in self?.openBuild($0) }
        )
        #if DEBUG
        actions.openDiagnostic = { [weak self] in self?.openUsageDiagnostic() }
        #endif
        return actions
    }

    private func importUsageExport() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = String(localized: "Choose a usage export downloaded from App Store Connect › Xcode Cloud › Usage.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await accounts.importUsageExport(at: url) }
    }

    #if DEBUG
    private func openUsageDiagnostic() {
        Task { await accounts.loadCaches() }
        diagnosticWindowController.show()
    }
    #endif

    // MARK: - Sleep

    @objc private func systemWillSleep(_ notification: Notification) {
        accounts.suspend()
    }

    @objc private func screenDidLock(_ notification: Notification) {
        accounts.screenLockDidChange(isLocked: true)
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        accounts.screenLockDidChange(isLocked: false)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        accounts.resume()
    }
}
