import AppKit

/// The menu bar shown while the main window is open. It also carries the key equivalents (⌘, ⌘Q ⌘W ⌘V) when it is hidden.
enum MainMenu {
    struct Actions {
        var openSettings: Selector
        var openPro: Selector
        var openMainWindow: Selector
        var refresh: Selector
        var openHelp: Selector
    }

    static func make(target: AnyObject, _ actions: Actions) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu: appMenu(target, actions))
        mainMenu.addItem(submenu: fileMenu(target, actions))
        mainMenu.addItem(submenu: editMenu())
        mainMenu.addItem(submenu: viewMenu())
        let window = windowMenu(target, actions)
        mainMenu.addItem(submenu: window)
        let help = helpMenu(target, actions)
        mainMenu.addItem(submenu: help)
        NSApp?.windowsMenu = window
        NSApp?.helpMenu = help
        return mainMenu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func appMenu(_ target: AnyObject, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Cumulus")
        item(menu, String(localized: "About Cumulus"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        item(menu, String(localized: "Settings…"), actions.openSettings, ",", target: target)
        item(menu, String(localized: "Cumulus Pro…"), actions.openPro, target: target)
        menu.addItem(.separator())
        item(menu, String(localized: "Hide Cumulus"), #selector(NSApplication.hide(_:)), "h")
        let hideOthers = item(menu, String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        item(menu, String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        item(menu, String(localized: "Quit Cumulus"), #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu(_ target: AnyObject, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        item(menu, String(localized: "Refresh"), actions.refresh, "r", target: target)
        menu.addItem(.separator())
        item(menu, String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        item(menu, String(localized: "Undo"), Selector(("undo:")), "z")
        let redo = item(menu, String(localized: "Redo"), Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        item(menu, String(localized: "Cut"), #selector(NSText.cut(_:)), "x")
        item(menu, String(localized: "Copy"), #selector(NSText.copy(_:)), "c")
        item(menu, String(localized: "Paste"), #selector(NSText.paste(_:)), "v")
        item(menu, String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        let sidebar = item(menu, String(localized: "Toggle Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(.separator())
        let fullScreen = item(menu, String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func windowMenu(_ target: AnyObject, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        item(menu, String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        item(menu, String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        item(menu, "Cumulus", actions.openMainWindow, "0", target: target)
        menu.addItem(.separator())
        item(menu, String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu(_ target: AnyObject, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))
        item(menu, String(localized: "Xcode Cloud Documentation"), actions.openHelp, target: target)
        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
