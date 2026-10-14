import AppKit
import Observation

/// Owns the menu bar item: its title follows the selected account's usage, and its menu is rebuilt each time it opens.
final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    private let accounts: AccountsModel
    private let appleStatus: AppleStatusStore?
    private var actions: StatusMenuActions
    private let now: () -> Date
    private let defaults: UserDefaults
    private var clock: Task<Void, Never>?
    /// Wakes the bar when the time left next changes; exists only while a build runs.
    private var timeLeftTask: Task<Void, Never>?
    private var settingsWatch: Task<Void, Never>?

    init(
        accounts: AccountsModel,
        actions: StatusMenuActions,
        appleStatus: AppleStatusStore? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.accounts = accounts
        self.appleStatus = appleStatus
        self.actions = actions
        self.now = now
        self.defaults = defaults
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        self.actions.selectAccount = { [weak self] in self?.selectAccount($0) }
        statusItem.button?.image = MenuBarIcon.image(badge: nil, measuring: false)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        followUsage()
        startClock()
        followSettings()
    }

    isolated deinit {
        clock?.cancel()
        timeLeftTask?.cancel()
        settingsWatch?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    var state: StatusMenuState {
        var current = Self.state(of: accounts, palette: accounts.selected?.paletteStore.load(from: defaults) ?? AppPalette(), now: now())
        current.hasAppleIncident = appleStatus?.ongoingIncident(at: current.now) != nil
        return current
    }

    /// What the menu shows: the selected account's builds and usage, and every account's name when there are several.
    static func state(of accounts: AccountsModel, palette: AppPalette, now date: Date) -> StatusMenuState {
        guard let session = accounts.selected else {
            return StatusMenuState(needsAPIKey: true, hasAccounts: false, isSyncing: false, now: date)
        }
        let buildStore = session.buildStore
        let settings = session.settings
        let summary = session.usageSummary(now: date)
        let measurement = session.measurement(now: date, summary: summary)
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
            activity: buildStore.progress,
            accounts: AccountChoice.all(of: accounts),
            selectedAccountID: session.id
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = refreshedState()
        if let switcher = StatusMenuBuilder.accountSwitcher(for: current, actions: actions) {
            menu.addItem(switcher)
            menu.addItem(.separator())
        }
        for item in body(for: current) {
            menu.addItem(item)
        }
    }

    /// Everything under the switcher. A shortcut closes the menu, which is rebuilt when it opens again: unlike a click
    /// in the switcher, it replaces nothing in place.
    private func body(for state: StatusMenuState) -> [NSMenuItem] {
        StatusMenuBuilder.accountShortcuts(for: state, select: { [accounts] in accounts.select($0) })
            + StatusMenuBuilder.items(for: state, actions: actions)
    }

    /// Picked in the open menu: the switcher stays where it is and shows the new account, everything under it is replaced.
    private func selectAccount(_ id: String) {
        accounts.select(id)
        guard let menu = statusItem.menu, let switcher = menu.items.first?.view as? AccountSwitcherControl else { return }
        let current = refreshedState()
        switcher.update(accounts: current.accounts, selectedID: current.selectedAccountID)
        while menu.numberOfItems > 2 {
            menu.removeItem(at: menu.numberOfItems - 1)
        }
        for item in body(for: current) {
            menu.addItem(item)
        }
    }

    /// Colours follow the apps for as long as they exist; the palette is saved only when it changed.
    private func refreshedState() -> StatusMenuState {
        var current = state
        if let session = accounts.selected {
            current.palette = session.paletteStore.refreshed(for: current.snapshot, summary: current.summary, defaults: defaults)
        }
        return current
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

    /// The setting that shows the time left lives in the app's preferences: the bar follows it without a restart.
    private func followSettings() {
        settingsWatch = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.refreshButton()
            }
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let current = state
        let timeLeft = timeLeft(at: current.now)
        button.title = StatusMenuBuilder.buttonTitle(
            for: current.summary, isFirstSync: current.isFirstSync,
            timeLeft: timeLeft.flatMap { BuildETAFormat.barText(runningCount: $0.runningCount, display: $0.display) }
        )
        let badge = currentBadge()
        let measuring = current.isFirstSync || current.measurement?.isMeasuring == true
        button.image = MenuBarIcon.image(badge: badge, measuring: measuring)
        let label = MenuBarBadge.accessibilityLabel(for: badge)
        button.setAccessibilityLabel(timeLeft?.display.map { [label, BuildETAFormat.spoken($0)].formatted(.list(type: .and, width: .narrow)) } ?? label)
        scheduleTimeLeftRefresh(timeLeft)
    }

    /// The builds running on every active account and when the nearest ends; nil when the setting is off.
    private func timeLeft(at date: Date) -> RunningBuildsETA? {
        guard BuildETAFeature.isOn(defaults) else { return nil }
        #if DEBUG
        // Shows the text without a running build: XCC_ETA=<minutes> (with XCC_BADGE=running for the dot).
        if let minutes = ProcessInfo.processInfo.environment["XCC_ETA"].flatMap(Double.init), minutes > 0 {
            return RunningBuildsETA(runningCount: 1, remaining: minutes * 60)
        }
        #endif
        return RunningBuildsETA(snapshots: accounts.activeSessions.map(\.buildStore.snapshot), now: date)
    }

    /// The text changes once a minute at most: a task sleeps until it does, and only while a build runs.
    private func scheduleTimeLeftRefresh(_ timeLeft: RunningBuildsETA?) {
        timeLeftTask?.cancel()
        timeLeftTask = nil
        guard let timeLeft, timeLeft.runningCount > 0 else { return }
        let delay = min(60, max(1, timeLeft.nextChange.map { $0.timeIntervalSince(now()) } ?? 60))
        timeLeftTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshButton()
        }
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
        // The dot speaks for every account: a build of an account that is not on screen still shows.
        return MenuBarBadge.status(for: accounts.activeSessions.map(\.buildStore.snapshot))
    }
}
