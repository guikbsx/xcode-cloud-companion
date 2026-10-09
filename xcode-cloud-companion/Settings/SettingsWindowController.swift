import AppKit
import SwiftUI

final class SettingsWindowController {
    private let model: SettingsModel
    private let loginItem: LoginItemModel
    private let usage: UsageStore
    private var window: NSWindow?

    init(model: SettingsModel, loginItem: LoginItemModel, usage: UsageStore) {
        self.model = model
        self.loginItem = loginItem
        self.usage = usage
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        loginItem.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, loginItem: loginItem, usage: usage)))
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
