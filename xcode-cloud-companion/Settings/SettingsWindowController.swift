import AppKit
import SwiftUI

/// The Settings window: four tabs in the toolbar, the way Xcode and Safari lay theirs out.
final class SettingsWindowController {
    /// Remembered by name: a tab that goes or comes does not shift the others.
    private enum Tab: String, CaseIterable {
        case general, accounts, notifications, agents

        var title: String {
            switch self {
            case .general: String(localized: "General", comment: "Settings tab")
            case .accounts: String(localized: "Accounts", comment: "Settings tab: the App Store Connect accounts")
            case .notifications: String(localized: "Notifications", comment: "Settings tab")
            case .agents: String(localized: "Agents", comment: "Settings tab: AI agents that can query the app")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .accounts: "person.2"
            case .notifications: "bell"
            case .agents: "terminal"
            }
        }

        var size: NSSize {
            switch self {
            case .general: NSSize(width: 560, height: 400)
            // The list of accounts on the left, an account's settings on the right.
            case .accounts: NSSize(width: 780, height: 720)
            case .notifications: NSSize(width: 560, height: 700)
            case .agents: NSSize(width: 560, height: 700)
            }
        }
    }

    private static let selectedTabKey = "settings.selectedTabName"

    private let accounts: AccountsModel
    private let loginItem: LoginItemModel
    private let notificationPreferences: NotificationPreferences
    private let notifications: NotificationCoordinator
    private let accountsTab = AccountsSettingsModel()
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

    /// `addingAccount` opens the Accounts tab on a new account's form.
    func show(addingAccount: Bool = false) {
        let window = window ?? makeWindow()
        self.window = window
        loginItem.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task {
            await accounts.whenReady()
            for session in accounts.sessions {
                await session.settings.load()
            }
            accountsTab.prepare(for: accounts, addingAccount: addingAccount)
            let tab = addingAccount ? .accounts : initialTab()
            tabController?.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: tab) ?? 0
            // Selecting the tab already shown sends no notification: the title is set here too.
            tabController?.title = tab.title
        }
    }

    /// Accounts while there is none, or one lacks its key or its reset date; otherwise the tab used last.
    private func initialTab() -> Tab {
        if accounts.sessions.isEmpty || accounts.sessions.contains(where: { !$0.settings.hasStoredKey || $0.settings.resetAnchor == nil }) {
            return .accounts
        }
        return defaults.string(forKey: Self.selectedTabKey).flatMap(Tab.init(rawValue:)) ?? .general
    }

    private func makeWindow() -> NSWindow {
        let controller = TabsController(onSelect: { [defaults] index in
            if Tab.allCases.indices.contains(index) {
                defaults.set(Tab.allCases[index].rawValue, forKey: Self.selectedTabKey)
            }
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
        case .accounts: AccountsSettingsView(accounts: accounts, model: accountsTab)
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
