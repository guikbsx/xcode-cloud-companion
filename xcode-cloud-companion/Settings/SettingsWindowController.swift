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

        /// What the tab opens at, and the least the window may be resized to while it shows.
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
        let controller = TabsController(
            onSelect: { [defaults] index in
                if Tab.allCases.indices.contains(index) {
                    defaults.set(Tab.allCases[index].rawValue, forKey: Self.selectedTabKey)
                }
            },
            minimumSize: { Tab.allCases.indices.contains($0) ? Tab.allCases[$0].size : nil }
        )
        controller.tabStyle = .toolbar
        for tab in Tab.allCases {
            // Opens at its size, grows with the window, never shrinks below it.
            let hosting = NSHostingController(rootView: rootView(for: tab).frame(
                minWidth: tab.size.width, idealWidth: tab.size.width, maxWidth: .infinity,
                minHeight: tab.size.height, idealHeight: tab.size.height, maxHeight: .infinity
            ))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        tabController = controller

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = Tab.allCases[controller.selectedTabViewItemIndex].size
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

/// Remembers the tab the user picked, so the window reopens on it, and keeps the window at least as large as the tab.
private final class TabsController: NSTabViewController {
    private let onSelect: (Int) -> Void
    private let minimumSize: (Int) -> NSSize?

    init(onSelect: @escaping (Int) -> Void, minimumSize: @escaping (Int) -> NSSize?) {
        self.onSelect = onSelect
        self.minimumSize = minimumSize
        super.init(nibName: nil, bundle: nil)
    }

    /// Set before the window takes the new tab's size: a larger minimum left by the previous tab would stand in its way.
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem, let size = minimumSize(tabView.indexOfTabViewItem(tabViewItem)) {
            view.window?.contentMinSize = size
        }
        super.tabView(tabView, willSelect: tabViewItem)
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
