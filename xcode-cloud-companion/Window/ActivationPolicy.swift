import AppKit

protocol ActivationPolicyControlling {
    @discardableResult func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

extension NSApplication: ActivationPolicyControlling {}

/// A menu bar app has no Dock icon and no menu bar of its own; its window gets both while it is open.
struct ActivationPolicyCoordinator {
    static let showsInDockKey = "showsInDock"

    let app: any ActivationPolicyControlling
    var showsInDock: () -> Bool = { UserDefaults.standard.object(forKey: Self.showsInDockKey) as? Bool ?? true }

    func windowWillShow() {
        if showsInDock() {
            app.setActivationPolicy(.regular)
        }
        app.activate()
    }

    func windowDidClose() {
        app.setActivationPolicy(.accessory)
    }
}
