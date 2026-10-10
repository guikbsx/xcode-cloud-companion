import AppKit
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsModel = SettingsModel()
    private let loginItemModel = LoginItemModel()
    private let buildStore = BuildStore()
    private let usageStore = UsageStore()
    private lazy var settingsWindowController = SettingsWindowController(model: settingsModel, loginItem: loginItemModel, usage: usageStore)
    private let navigation = NavigationModel()
    private lazy var mainWindowController = MainWindowController(
        buildStore: buildStore,
        usageStore: usageStore,
        settings: settingsModel,
        navigation: navigation,
        activation: ActivationPolicyCoordinator(app: NSApp),
        openSettings: { [weak self] in self?.openSettings() }
    )
    private var statusItemController: StatusItemController?
    #if DEBUG
    private lazy var diagnosticWindowController = UsageDiagnosticWindowController(buildStore: buildStore, settings: settingsModel)
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
            openMainWindow: #selector(openMainWindow),
            refresh: #selector(refresh),
            openHelp: #selector(openHelp)
        ))
        statusItemController = StatusItemController(
            buildStore: buildStore,
            usageStore: usageStore,
            settings: settingsModel,
            actions: menuActions()
        )

        settingsModel.onCredentialsChange = { [buildStore] in
            Task { await buildStore.credentialsDidChange() }
        }
        settingsModel.onReset = { [usageStore] in
            await BuildExtrasCache().deleteAll()
            await WorkflowDetailsCache().deleteAll()
            await usageStore.reset()
        }

        // Unit tests run inside this app: they must not reach App Store Connect with the user's real key.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(self, selector: #selector(screenDidLock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributedCenter.addObserver(self, selector: #selector(screenDidUnlock), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        buildStore.start()
        // The Issuer ID is the team in App Store Connect's addresses: the menu's links need it before Settings ever opens.
        Task { await settingsModel.load() }
        Task { await usageStore.start() }
    }

    @objc func openSettings() {
        settingsWindowController.show()
    }

    @objc func openMainWindow() {
        mainWindowController.show()
    }

    @objc private func refresh() {
        Task {
            await usageStore.scanWatchedDirectory()
            await buildStore.refreshNow()
        }
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/documentation/xcode/xcode-cloud")!)
    }

    func openBuild(_ id: String) {
        navigation.showBuild(id)
        mainWindowController.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where navigation.open(url) {
            mainWindowController.show()
        }
    }

    private func menuActions() -> StatusMenuActions {
        var actions = StatusMenuActions(
            refresh: { [weak self] in self?.refresh() },
            openUsagePage: { [settingsModel] in
                NSWorkspace.shared.open(AppStoreConnectLinks.xcodeCloudUsage(teamID: settingsModel.issuerID))
            },
            importUsageExport: { [weak self] in self?.importUsageExport() },
            openSettings: { [weak self] in self?.openSettings() },
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
        Task { await usageStore.importFile(at: url) }
    }

    #if DEBUG
    private func openUsageDiagnostic() {
        Task { await buildStore.loadCacheIfNeeded() }
        diagnosticWindowController.show()
    }
    #endif

    // MARK: - Sleep

    @objc private func systemWillSleep(_ notification: Notification) {
        buildStore.stop()
        usageStore.stop()
    }

    @objc private func screenDidLock(_ notification: Notification) {
        buildStore.screenLockDidChange(isLocked: true)
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        buildStore.screenLockDidChange(isLocked: false)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        buildStore.start()
        // The Issuer ID is the team in App Store Connect's addresses: the menu's links need it before Settings ever opens.
        Task { await settingsModel.load() }
        Task { await usageStore.start() }
    }
}
