import AppKit
import SwiftUI

/// The main window: an `NSWindow` hosting SwiftUI, like Settings. A SwiftUI `Window` scene cannot be opened from an `NSMenu` item.
final class MainWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "MainWindow"

    private let accounts: AccountsModel
    private let pins = PinnedWorkflows()
    private let navigation: NavigationModel
    private let activation: ActivationPolicyCoordinator
    private let openSettings: () -> Void
    private var window: NSWindow?

    init(accounts: AccountsModel, navigation: NavigationModel, activation: ActivationPolicyCoordinator, openSettings: @escaping () -> Void) {
        self.accounts = accounts
        self.navigation = navigation
        self.activation = activation
        self.openSettings = openSettings
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        activation.windowWillShow()
        window.makeKeyAndOrderFront(nil)
        accounts.windowDidOpen()
        Task { [accounts] in await accounts.loadCaches() }
    }

    func windowWillClose(_ notification: Notification) {
        activation.windowDidClose()
        accounts.windowDidClose()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowRoot(accounts: accounts, navigation: navigation, pins: pins, openSettings: openSettings))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Cumulus"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 560)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}
