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
    private let badgeView = MenuBarBadgeView(frame: .zero)
    private let cloudBounds: NSRect
    private let measuringCloud: NSImage
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
        let cloud = CloudLevelGlyph.image(level: nil)
        cloudBounds = cloud.drawnBounds
        measuringCloud = Self.dimmed(cloud)
        super.init()
        statusItem.button?.image = cloud
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.addSubview(badgeView)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        followUsage()
        startClock()
    }

    @objc private func displayOptionsDidChange() {
        badgeView.needsDisplay = true
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clock?.cancel()
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
            palette: palette,
            lastSync: buildStore.snapshot.lastSuccessfulSync,
            syncStartedAt: buildStore.syncStartedAt,
            isSyncing: buildStore.isSyncing,
            errorMessage: buildStore.lastErrorMessage,
            now: date,
            teamID: settings.issuerID.isEmpty ? nil : settings.issuerID
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

    /// A finished build's dot expires after ten minutes without any data changing, so time moves it too.
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
        let summary = state.summary
        button.title = StatusMenuBuilder.buttonTitle(for: summary)
        // While the first figures are being measured the cloud fades, without any animation; then it fills with the usage.
        if let summary, summary.measurement.isMeasuring {
            button.image = measuringCloud
        } else {
            button.image = CloudLevelGlyph.image(level: summary?.fractionUsed)
        }
        let badge = currentBadge()
        badgeView.badge = badge
        button.setAccessibilityLabel(MenuBarBadge.accessibilityLabel(for: badge))
        placeBadge(on: button)
    }

    private func currentBadge() -> MenuBarBadge? {
        #if DEBUG
        // Lets a Debug build show each dot without waiting for a build: XCC_BADGE=running|failed|succeeded|none.
        switch ProcessInfo.processInfo.environment["XCC_BADGE"] {
        case "running": return .running
        case "failed": return .failed
        case "succeeded": return .succeeded
        case "none": return nil
        default: break
        }
        #endif
        return MenuBarBadge.status(for: buildStore.snapshot, now: now())
    }

    /// The same symbol at 60 % opacity, still a template so the menu bar tints it.
    private static func dimmed(_ image: NSImage) -> NSImage {
        let faded = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.6)
            return true
        }
        faded.isTemplate = true
        faded.accessibilityDescription = image.accessibilityDescription
        return faded
    }

    /// The cell centres the image in its rectangle, so the placement starts from that rectangle's middle.
    private func placeBadge(on button: NSStatusBarButton) {
        guard let image = button.image, let cell = button.cell else { return }
        let area = cell.imageRect(forBounds: button.bounds)
        guard area.width > 0, cloudBounds.width > 0 else { return }
        badgeView.setFrameOrigin(MenuBarBadgePlacement.frameOrigin(
            imageAreaMid: NSPoint(x: area.midX, y: area.midY),
            imageSize: image.size,
            glyph: cloudBounds,
            badgeSize: MenuBarBadgeView.size,
            isFlipped: button.isFlipped
        ))
    }
}
