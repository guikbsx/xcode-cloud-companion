import AppKit
import SwiftUI

/// The Settings window: five tabs in the toolbar, the way Xcode and Safari lay theirs out.
final class SettingsWindowController {
    private enum Tab: Int, CaseIterable {
        case general, configuration, usage, notifications, agents

        var title: String {
            switch self {
            case .general: String(localized: "General", comment: "Settings tab")
            case .configuration: String(localized: "Configuration", comment: "Settings tab")
            case .usage: String(localized: "Usage", comment: "Settings tab")
            case .notifications: String(localized: "Notifications", comment: "Settings tab")
            case .agents: String(localized: "Agents", comment: "Settings tab: AI agents that can query the app")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .configuration: "slider.horizontal.3"
            case .usage: "chart.bar"
            case .notifications: "bell"
            case .agents: "terminal"
            }
        }

        var size: NSSize {
            switch self {
            case .general: NSSize(width: 560, height: 400)
            case .configuration: NSSize(width: 560, height: 740)
            case .usage: NSSize(width: 560, height: 340)
            case .notifications: NSSize(width: 560, height: 700)
            case .agents: NSSize(width: 560, height: 700)
            }
        }
    }

    private static let selectedTabKey = "settings.selectedTab"

    private let accounts: AccountsModel
    private let loginItem: LoginItemModel
    private let notificationPreferences: NotificationPreferences
    private let notifications: NotificationCoordinator
    private let agents = AgentsSettingsModel()
    private let defaults: UserDefaults
    private var window: NSWindow?
    private var tabController: NSTabViewController?

    init(
        accounts: AccountsModel, loginItem: LoginItemModel, notificationPreferences: NotificationPreferences,
        notifications: NotificationCoordinator, defaults: UserDefaults = .standard
    ) {
        self.accounts = accounts
        self.loginItem = loginItem
        self.notificationPreferences = notificationPreferences
        self.notifications = notifications
        self.defaults = defaults
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        loginItem.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task {
            for session in accounts.sessions {
                await session.settings.load()
            }
            let tab = initialTab()
            tabController?.selectedTabViewItemIndex = tab.rawValue
            // Selecting the tab already shown sends no notification: the title is set here too.
            tabController?.title = tab.title
        }
    }

    /// Configuration while the key or the reset date of the account on screen is missing, otherwise the tab used last.
    private func initialTab() -> Tab {
        let model = accounts.selected.settings
        if !model.hasStoredKey || model.resetAnchor == nil {
            return .configuration
        }
        return Tab(rawValue: defaults.integer(forKey: Self.selectedTabKey)) ?? .general
    }

    private func makeWindow() -> NSWindow {
        let controller = TabsController(onSelect: { [defaults] index in
            defaults.set(index, forKey: Self.selectedTabKey)
        })
        controller.tabStyle = .toolbar
        for tab in Tab.allCases {
            let hosting = NSHostingController(rootView: rootView(for: tab).frame(width: tab.size.width, height: tab.size.height))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        tabController = controller

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    @ViewBuilder
    private func rootView(for tab: Tab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(loginItem: loginItem)
        case .configuration: ConfigurationSettingsRoot(accounts: accounts)
        case .usage: UsageSettingsView(accounts: accounts)
        case .notifications: NotificationsSettingsView(preferences: notificationPreferences, coordinator: notifications, accounts: accounts)
        case .agents: AgentsSettingsView(model: agents)
        }
    }
}

/// Remembers the tab the user picked, so the window reopens on it.
private final class TabsController: NSTabViewController {
    private let onSelect: (Int) -> Void

    init(onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabsController is never decoded")
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tabViewItem {
            // The window takes its title from its content view controller.
            title = tabViewItem.label
            onSelect(tabView.indexOfTabViewItem(tabViewItem))
        }
    }
}
