import AppKit

final class StatusItemController {
    let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "cloud",
            accessibilityDescription: String(localized: "Xcode Cloud Companion")
        )
        statusItem.menu = Self.makeMenu()
    }

    isolated deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Quit Xcode Cloud Companion"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }
}
