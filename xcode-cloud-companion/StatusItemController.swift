import AppKit
import Observation

/// Owns the menu bar item: its title follows the usage, and its menu is rebuilt each time it opens.
final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    private let buildStore: BuildStore
    private let usageStore: UsageStore
    private let settings: SettingsModel
    private let actions: StatusMenuActions
    private let now: () -> Date

    init(
        buildStore: BuildStore,
        usageStore: UsageStore,
        settings: SettingsModel,
        actions: StatusMenuActions,
        now: @escaping () -> Date = { Date() }
    ) {
        self.buildStore = buildStore
        self.usageStore = usageStore
        self.settings = settings
        self.actions = actions
        self.now = now
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "cloud",
            accessibilityDescription: String(localized: "Xcode Cloud Companion")
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        followUsage()
    }

    isolated deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    var state: StatusMenuState {
        let date = now()
        let summary = settings.plan.map {
            UsageCalculator.summary(snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: date)
        }
        return StatusMenuState(
            needsAPIKey: !buildStore.isConfigured && buildStore.snapshot.lastSuccessfulSync == nil && !buildStore.isSyncing,
            summary: summary,
            snapshot: buildStore.snapshot,
            lastSync: buildStore.snapshot.lastSuccessfulSync,
            isSyncing: buildStore.isSyncing,
            errorMessage: buildStore.lastErrorMessage,
            now: date
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in StatusMenuBuilder.items(for: state, actions: actions) {
            menu.addItem(item)
        }
    }

    /// Keeps the percentage next to the icon in step with the data it is computed from.
    private func followUsage() {
        withObservationTracking {
            statusItem.button?.title = StatusMenuBuilder.buttonTitle(for: state.summary)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followUsage() }
        }
    }
}
