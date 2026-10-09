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
    var lastSync: Date?
    var isSyncing: Bool
    var errorMessage: String?
    var now: Date
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
    static func items(for state: StatusMenuState, actions: StatusMenuActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if state.needsAPIKey {
            items.append(NSMenuItem.action(String(localized: "Set Up Your App Store Connect API Key…"), handler: actions.openSettings))
            items.append(.separator())
        }

        if let summary = state.summary {
            items.append(viewItem(UsageHeaderView(summary: summary)))
            items.append(viewItem(UsageStatsView(summary: summary)))
            items.append(viewItem(UsageHistogramView(daily: summary.daily)))
        } else {
            items.append(NSMenuItem.action(String(localized: "Set Your Plan’s Reset Date…"), handler: actions.openSettings))
        }
        items.append(.separator())
        items += AppBuildsMenu.items(snapshot: state.snapshot, summary: state.summary, now: state.now, open: actions.openURL)

        let status = NSMenuItem(title: statusLine(for: state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        if state.errorMessage != nil {
            status.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
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
        items.append(NSMenuItem(
            title: String(localized: "Quit Xcode Cloud Companion"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return items
    }

    static func statusLine(for state: StatusMenuState) -> String {
        if state.isSyncing {
            return String(localized: "Updating…")
        }
        if let errorMessage = state.errorMessage {
            return errorMessage
        }
        guard let lastSync = state.lastSync else {
            return String(localized: "Not updated yet")
        }
        return String(localized: "Updated \(UsageFormat.relative(lastSync, now: state.now))")
    }

    static func buttonTitle(for summary: UsageSummary?) -> String {
        summary.map { UsageFormat.percent($0.fractionUsed) } ?? ""
    }

    private static func viewItem(_ view: some View) -> NSMenuItem {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}
