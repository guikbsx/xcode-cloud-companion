import AppKit
import SwiftUI

/// The main window: an `NSWindow` hosting SwiftUI, like Settings. A SwiftUI `Window` scene cannot be opened from an `NSMenu` item.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let frameName = "MainWindow"
    /// What the window opens at the first time, and the least it may be resized to: three columns that still read.
    static let openingSize = NSSize(width: 1180, height: 740)
    static let minimumSize = NSSize(width: 900, height: 560)

    private let accounts: AccountsModel
    private let pins = PinnedWorkflows()
    private let navigation: NavigationModel
    private let activation: ActivationPolicyCoordinator
    private let openSettings: () -> Void
    /// The name the window's frame is saved under; nil neither restores nor saves it.
    private let frameName: String?
    private(set) var window: NSWindow?
    private let purchase: ProPurchasePresenter?
    private var access: ProAccess?

    init(
        accounts: AccountsModel, navigation: NavigationModel, activation: ActivationPolicyCoordinator, openSettings: @escaping () -> Void,
        pro: ProStore? = nil, purchase: ProPurchasePresenter? = nil, frameName: String? = MainWindowController.frameName
    ) {
        self.accounts = accounts
        self.navigation = navigation
        self.activation = activation
        self.openSettings = openSettings
        self.frameName = frameName
        self.purchase = purchase
        super.init()
        // Without a store (tests), the window treats every function as open.
        access = pro.map { store in
            ProAccess(store: store) { [weak self] feature in
                guard let self, let window = self.window else { return }
                self.purchase?.present(over: window, origin: feature)
            }
        }
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
        let hosting = NSHostingController(rootView: MainWindowRoot(accounts: accounts, navigation: navigation, pins: pins, openSettings: openSettings, pro: access))
        // The size is the window's own. Left to itself, the hosting controller resizes the window to the least its
        // content can be, 591 × 190 points, and that tiny frame is then the one saved (seen on 12/10/2026).
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Cumulus"
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let frameName, window.setFrameUsingName(frameName) {
            // A frame saved while the window could still shrink below its minimum opens at the minimum.
            let saved = window.contentRect(forFrameRect: window.frame).size
            if saved.width < Self.minimumSize.width || saved.height < Self.minimumSize.height {
                window.setContentSize(NSSize(width: max(saved.width, Self.minimumSize.width), height: max(saved.height, Self.minimumSize.height)))
            }
        } else {
            window.setContentSize(Self.openingSize)
            window.center()
        }
        if let frameName {
            window.setFrameAutosaveName(frameName)
        }
        return window
    }

    /// The minimum is held here, as for Settings: the SwiftUI content clears a `contentMinSize` set on the window.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }
}
