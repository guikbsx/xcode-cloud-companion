import AppKit
import SwiftUI

struct StatusMenuActions {
    var refresh: () -> Void = {}
    var openUsagePage: () -> Void = {}
    var importUsageExport: () -> Void = {}
    var openSettings: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
    var openDiagnostic: (() -> Void)?
}

struct StatusMenuState {
    var needsAPIKey: Bool
    var summary: UsageSummary?
    var snapshot: BuildSnapshot = .empty
    var palette = AppPalette()
    var lastSync: Date?
    var syncStartedAt: Date?
    var isSyncing: Bool
    var errorMessage: String?
    var now: Date
    /// The Issuer ID, which App Store Connect uses as the team in its addresses.
    var teamID: String?
    /// Measurement of the builds, even without a plan (then over the last 30 days); `summary` carries it otherwise.
    var measurement: MeasurementProgress?
    /// What the synchronizer is doing right now (“Listing builds of …”).
    var activity: String?

    /// The first synchronization of a key: nothing has been read yet.
    var isFirstSync: Bool { isSyncing && lastSync == nil }
}

/// Target of a menu item that runs a closure; the item keeps it alive through `representedObject`.
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) {
        handler()
    }
}

extension NSMenuItem {
    static func action(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: keyEquivalent)
        item.target = target
        item.representedObject = target
        return item
    }
}

enum StatusMenuBuilder {
    /// A tinted triangle ahead of the text: the menu draws no item image.
    static func warningTitle(_ text: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: "\u{25B2} ", attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        return title
    }

    static func items(for state: StatusMenuState, actions: StatusMenuActions) -> [NSMenuItem] {
        // Without a key there is nothing to show: one way in, one way out. Settings open on Configuration then.
        if state.needsAPIKey {
            return [
                NSMenuItem.action(String(localized: "Configure Cumulus…"), handler: actions.openSettings),
                .separator(),
                quitItem(),
            ]
        }

        var items: [NSMenuItem] = []

        let measurement = state.summary?.measurement ?? state.measurement ?? MeasurementProgress()
        if state.isFirstSync || measurement.isMeasuring {
            items.append(viewItem(MeasuringHeaderView(progress: measurement, isFirstSync: state.isFirstSync, activity: state.activity)))
            items.append(.separator())
        }

        let latest = LatestBuildsMenu.items(snapshot: state.snapshot, now: state.now, teamID: state.teamID, open: actions.openURL)
        if !latest.isEmpty {
            items += latest
            items.append(.separator())
        }

        if let summary = state.summary {
            items.append(viewItem(UsageGaugeView(summary: summary, palette: state.palette)))
        } else {
            items.append(NSMenuItem.action(String(localized: "Set Your Plan’s Reset Date…"), handler: actions.openSettings))
        }
        items.append(.separator())
        items += AppBuildsMenu.items(snapshot: state.snapshot, summary: state.summary, palette: state.palette, now: state.now, teamID: state.teamID, open: actions.openURL)

        let status = NSMenuItem(title: statusLine(for: state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        if state.errorMessage != nil {
            status.attributedTitle = warningTitle(status.title)
        }
        items.append(status)
        let refresh = NSMenuItem.action(String(localized: "Refresh"), keyEquivalent: "r", handler: actions.refresh)
        refresh.isEnabled = !state.isSyncing
        items.append(refresh)
        items.append(NSMenuItem.action(String(localized: "Update from App Store Connect"), handler: actions.openUsagePage))
        items.append(NSMenuItem.action(String(localized: "Import Usage Export…"), handler: actions.importUsageExport))
        items.append(.separator())

        if let openDiagnostic = actions.openDiagnostic {
            items.append(NSMenuItem.action("Usage Diagnostic…", handler: openDiagnostic))
        }
        items.append(NSMenuItem.action(String(localized: "Settings…"), keyEquivalent: ",", handler: actions.openSettings))
        items.append(quitItem())
        return items
    }

    private static func quitItem() -> NSMenuItem {
        NSMenuItem(title: String(localized: "Quit Cumulus"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    static func statusLine(for state: StatusMenuState) -> String {
        if state.isSyncing {
            guard let started = state.syncStartedAt, state.now.timeIntervalSince(started) >= 60 else {
                return String(localized: "Updating…")
            }
            return String(localized: "Syncing · started \(UsageFormat.relative(started, now: state.now))")
        }
        if let errorMessage = state.errorMessage {
            return errorMessage
        }
        guard let lastSync = state.lastSync else {
            return String(localized: "Not updated yet")
        }
        return String(localized: "Updated \(UsageFormat.relative(lastSync, now: state.now))")
    }

    static func buttonTitle(for summary: UsageSummary?, isFirstSync: Bool = false) -> String {
        guard let summary else { return isFirstSync ? "…" : "" }
        return summary.measurement.isMeasuring ? "…" : UsageFormat.compactPercent(summary.fractionUsed)
    }

    private static func viewItem(_ view: some View) -> NSMenuItem {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize
        // The menu widens its items to its widest row: the block follows instead of leaving a gap on the right.
        hostingView.autoresizingMask = [.width]
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}
