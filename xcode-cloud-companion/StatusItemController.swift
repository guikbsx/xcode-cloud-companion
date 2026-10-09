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
    private let paletteStore: AppPaletteStore
    private let defaults: UserDefaults
    private var palette: AppPalette
    private var clock: Task<Void, Never>?

    init(
        buildStore: BuildStore,
        usageStore: UsageStore,
        settings: SettingsModel,
        actions: StatusMenuActions,
        paletteStore: AppPaletteStore = AppPaletteStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.buildStore = buildStore
        self.usageStore = usageStore
        self.settings = settings
        self.actions = actions
        self.now = now
        self.paletteStore = paletteStore
        self.defaults = defaults
        palette = paletteStore.load(from: defaults)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = MenuBarIcon.image(badge: nil, measuring: false)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        followUsage()
        startClock()
    }

    isolated deinit {
        clock?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    var state: StatusMenuState {
        let date = now()
        let summary = settings.plan.map {
            UsageCalculator.summary(snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: date)
        }
        // Without a reset date there is no cycle, but the builds still get measured: over the last 30 days then.
        let measurement = summary?.measurement ?? UsageCalculator.summary(
            snapshot: buildStore.snapshot, ledger: usageStore.ledger,
            plan: UsagePlan(hours: settings.planHours, resetAnchor: date.addingTimeInterval(-30 * 24 * 3600)), now: date
        ).measurement
        return StatusMenuState(
            needsAPIKey: !buildStore.isConfigured && buildStore.snapshot.lastSuccessfulSync == nil && !buildStore.isSyncing,
            summary: summary,
            snapshot: buildStore.snapshot,
            palette: palette,
            lastSync: buildStore.snapshot.lastSuccessfulSync,
            syncStartedAt: buildStore.syncStartedAt,
            isSyncing: buildStore.isSyncing,
            errorMessage: buildStore.lastErrorMessage,
            now: date,
            teamID: settings.issuerID.isEmpty ? nil : settings.issuerID,
            measurement: measurement,
            activity: buildStore.progress
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var current = state
        refreshPalette(for: current)
        current.palette = palette
        for item in StatusMenuBuilder.items(for: current, actions: actions) {
            menu.addItem(item)
        }
    }

    /// Colours follow the apps for as long as they exist; the palette is saved only when it changed.
    private func refreshPalette(for state: StatusMenuState) {
        let ranking = AppPalette.ranking(
            byConsumption: state.summary?.appsByConsumption ?? [],
            allApps: state.snapshot.products.map(\.name)
        )
        if palette.update(ranking: ranking) {
            paletteStore.save(palette, to: defaults)
        }
    }

    /// Keeps the percentage and the dot next to the icon in step with the data they are computed from.
    private func followUsage() {
        withObservationTracking {
            refreshButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followUsage() }
        }
    }

    /// The menu bar shows what changes with time alone (measuring, the first sync), so it is redrawn every 30 seconds too.
    private func startClock() {
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refreshButton()
            }
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let current = state
        button.title = StatusMenuBuilder.buttonTitle(for: current.summary, isFirstSync: current.isFirstSync)
        let badge = currentBadge()
        let measuring = current.isFirstSync || current.measurement?.isMeasuring == true
        button.image = MenuBarIcon.image(badge: badge, measuring: measuring)
        button.setAccessibilityLabel(MenuBarBadge.accessibilityLabel(for: badge))
    }

    private func currentBadge() -> MenuBarBadge? {
        #if DEBUG
        // Lets a Debug build show each dot without waiting for a build: XCC_BADGE=running|failed|succeeded|stopped|none.
        switch ProcessInfo.processInfo.environment["XCC_BADGE"] {
        case "running": return .running
        case "failed": return .failed
        case "succeeded": return .succeeded
        case "stopped": return .stopped
        case "none": return nil
        default: break
        }
        #endif
        return MenuBarBadge.status(for: buildStore.snapshot)
    }
}
