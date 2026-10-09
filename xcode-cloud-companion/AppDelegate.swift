import AppKit
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsModel = SettingsModel()
    private let loginItemModel = LoginItemModel()
    private let buildStore = BuildStore()
    private let usageStore = UsageStore()
    private lazy var settingsWindowController = SettingsWindowController(model: settingsModel, loginItem: loginItemModel, usage: usageStore)
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
        // A menu bar app shows no main menu, but its key equivalents still drive ⌘, and copy/paste in text fields.
        NSApp.mainMenu = MainMenu.make(settingsTarget: self, settingsAction: #selector(openSettings))
        statusItemController = StatusItemController(
            buildStore: buildStore,
            usageStore: usageStore,
            settings: settingsModel,
            actions: menuActions()
        )

        settingsModel.onCredentialsChange = { [buildStore] in
            Task { await buildStore.credentialsDidChange() }
        }

        // Unit tests run inside this app: they must not reach App Store Connect with the user's real key.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        buildStore.start()
        Task { await usageStore.start() }
    }

    @objc func openSettings() {
        settingsWindowController.show()
    }

    private func menuActions() -> StatusMenuActions {
        var actions = StatusMenuActions(
            refresh: { [buildStore, usageStore] in
                Task {
                    await usageStore.scanWatchedDirectory()
                    await buildStore.refreshNow()
                }
            },
            openUsagePage: { NSWorkspace.shared.open(AppStoreConnectLinks.xcodeCloudUsage) },
            importUsageExport: { [weak self] in self?.importUsageExport() },
            openSettings: { [weak self] in self?.openSettings() },
            openURL: { NSWorkspace.shared.open($0) }
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

    @objc private func systemDidWake(_ notification: Notification) {
        buildStore.start()
        Task { await usageStore.start() }
    }
}
