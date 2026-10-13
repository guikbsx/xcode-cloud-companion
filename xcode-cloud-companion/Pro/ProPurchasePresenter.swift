import AppKit
import SwiftUI

/// Shows the purchase sheet over a window. It never opens by itself: a locked function, Settings or the Cumulus menu
/// ask for it.
final class ProPurchasePresenter {
    private let store: ProStore
    private var sheet: NSWindow?

    init(store: ProStore) {
        self.store = store
    }

    var isPresenting: Bool { sheet != nil }

    /// `origin` is the locked function one comes from: its benefit is read first.
    func present(over parent: NSWindow, origin: ProFeature? = nil) {
        guard sheet == nil else { return }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let model = ProPurchaseModel(store: store, origin: origin) { [weak parent, weak window] in
            guard let parent, let window else { return }
            parent.endSheet(window)
        }
        let controller = NSHostingController(rootView: ProPurchaseView(model: model))
        // The sheet follows its content: the prices arrive after it opens.
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        sheet = window
        parent.beginSheet(window) { [weak self] _ in
            self?.sheet = nil
        }
    }
}
