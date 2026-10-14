import AppKit
import SwiftUI

/// The Settings window: an `NSWindow` hosting a sidebar and the pane it picks, like the main window. A SwiftUI
/// `Settings` scene does not open from an `NSMenu`.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// What the window opens at, and the least it may be resized to: its panes scroll.
    static let openingSize = NSSize(width: 900, height: 720)
    static let minimumSize = NSSize(width: 700, height: 460)

    private let accounts: AccountsModel
    private let loginItem: LoginItemModel
    private let notificationPreferences: NotificationPreferences
    private let notifications: NotificationCoordinator
    private let navigation: SettingsNavigationModel
    private let pro: ProStore
    private let purchase: ProPurchasePresenter
    private let webhook: WebhookService
    private let agents = AgentsSettingsModel()
    private var window: NSWindow?

    init(
        accounts: AccountsModel, loginItem: LoginItemModel, notificationPreferences: NotificationPreferences,
        notifications: NotificationCoordinator, pro: ProStore, purchase: ProPurchasePresenter, webhook: WebhookService, defaults: UserDefaults = .standard
    ) {
        self.accounts = accounts
        self.loginItem = loginItem
        self.notificationPreferences = notificationPreferences
        self.notifications = notifications
        self.pro = pro
        self.purchase = purchase
        self.webhook = webhook
        navigation = SettingsNavigationModel(defaults: defaults)
        super.init()
    }

    /// `addingAccount` opens the window on a new account's form; `pane` on that pane whatever an account needs.
    func show(addingAccount: Bool = false, pane: SettingsNavigationModel.Pane? = nil) {
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
            navigation.open(for: accounts, addingAccount: addingAccount)
            if let pane { navigation.pane = pane }
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(
            accounts: accounts, navigation: navigation, loginItem: loginItem,
            notificationPreferences: notificationPreferences, notifications: notifications, webhook: webhook, agents: agents,
            pro: pro, openPurchase: { [weak self] in
                guard let self, let window = self.window else { return }
                self.purchase.present(over: window)
            }
        ))
        // The size is the window's own: a hosting controller that keeps reporting one would pin the window to it.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = String(localized: "Settings", comment: "Title of the Settings window")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.openingSize)
        window.center()
        return window
    }

    /// The minimum is held here: the SwiftUI content clears a `contentMinSize` set on the window (seen on 12/10/2026).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }
}
