import AppKit
import ServiceManagement
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct SettingsWindowTests {
    private final class NoLoginItem: LoginItemControlling {
        var status: SMAppService.Status { .notRegistered }
        func register() throws {}
        func unregister() throws {}
        func openSystemSettings() {}
    }

    private func controller(_ accounts: TestAccounts) -> SettingsWindowController {
        let preferences = NotificationPreferences(defaults: accounts.defaults)
        let pro = ProStore(source: StubProSource())
        return SettingsWindowController(
            accounts: accounts.model, loginItem: LoginItemModel(loginItem: NoLoginItem()), notificationPreferences: preferences,
            notifications: NotificationCoordinator(center: MockNotificationCenter(), preferences: preferences, defaults: accounts.defaults),
            pro: pro, purchase: ProPurchasePresenter(store: pro), defaults: accounts.defaults
        )
    }

    @Test func theWindowOpensAtItsSizeGoesDownToAMinimumAndKeepsTheSizeTheUserGivesIt() async throws {
        let controller = controller(TestAccounts())
        controller.show()
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "settings" })
        defer { window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

        try await settle()
        #expect(window.styleMask.contains(.resizable))
        #expect(!(window.contentViewController is NSTabViewController), "a sidebar, no tabs")
        #expect(window.contentLayoutRect.width == 900 && window.frame.height >= 700)
let smallest = try #require(window.delegate?.windowWillResize?(window, to: NSSize(width: 100, height: 100)))
        #expect(smallest.width == 700 && smallest.height >= 460, "it never gets smaller than what still reads")
        #expect(window.delegate?.windowWillResize?(window, to: NSSize(width: 1000, height: 800)) == NSSize(width: 1000, height: 800))

        // The user drags the window to another size: nothing brings it back, and the same window is shown again.
        let chosen = NSSize(width: 760, height: 520)
        window.setContentSize(chosen)
        try await settle()
        let kept = window.frame.size
        controller.show()
        try await settle()
        #expect(window.frame.size == kept && abs(kept.width - chosen.width) < 1)
        #expect(NSApp.windows.filter { $0.identifier?.rawValue == "settings" && $0.isVisible }.count == 1)
    }

    @Test(.disabled("The Settings are a sidebar window since XCO-97: there are no tabs to size any more. Kept for the record; theWindowOpensAtItsSizeGoesDownToAMinimumAndKeepsTheSizeTheUserGivesIt replaces it."))
    func theWindowKeepsTheSizeTheUserGivesItDownToAMinimumAndEachTabOpensAtItsOwn() async throws {
        let accounts = TestAccounts()
        let preferences = NotificationPreferences(defaults: accounts.defaults)
        let pro = ProStore(source: StubProSource())
        let controller = SettingsWindowController(
            accounts: accounts.model, loginItem: LoginItemModel(loginItem: NoLoginItem()), notificationPreferences: preferences,
            notifications: NotificationCoordinator(center: MockNotificationCenter(), preferences: preferences, defaults: accounts.defaults),
            pro: pro, purchase: ProPurchasePresenter(store: pro), defaults: accounts.defaults
        )
        controller.show()
        let window = try #require(NSApp.windows.first { $0.contentViewController is NSTabViewController })
        defer { window.close() }
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }

        #expect(window.styleMask.contains(.resizable))
        // Without an account, Settings open on Accounts: at its own size, and it may be made smaller than that.
        for _ in 0..<50 where tabs.selectedTabViewItemIndex != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
        #expect(tabs.selectedTabViewItemIndex == 1 && window.contentLayoutRect.size == NSSize(width: 780, height: 720))
        #expect(window.contentMinSize == NSSize(width: 700, height: 460), "min \(window.contentMinSize) layout \(window.contentLayoutRect.size) frame \(window.frame.size)")

        // The user drags the window to another size: it stays there, where the tab controller used to bring it back.
        window.setContentSize(NSSize(width: 900, height: 600))
        window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        try await settle()
        #expect(window.contentLayoutRect.size == NSSize(width: 900, height: 600))

        // Another tab opens at its own size, with its own minimum.
        tabs.selectedTabViewItemIndex = 0
        try await settle()
        #expect(window.contentLayoutRect.size == NSSize(width: 560, height: 400))
        #expect(window.contentMinSize == NSSize(width: 560, height: 400))
        tabs.selectedTabViewItemIndex = 3
        try await settle()
        #expect(window.contentLayoutRect.size == NSSize(width: 560, height: 700) && window.contentMinSize == NSSize(width: 560, height: 420))

        // Coming back, Accounts opens at its own size again, not at the one it was dragged to.
        tabs.selectedTabViewItemIndex = 1
        try await settle()
        #expect(window.contentLayoutRect.size == NSSize(width: 780, height: 720))
    }
}
