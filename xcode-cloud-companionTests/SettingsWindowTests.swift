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

    @Test func theWindowKeepsTheSizeTheUserGivesItDownToAMinimumAndEachTabOpensAtItsOwn() async throws {
        let accounts = TestAccounts()
        let preferences = NotificationPreferences(defaults: accounts.defaults)
        let controller = SettingsWindowController(
            accounts: accounts.model, loginItem: LoginItemModel(loginItem: NoLoginItem()), notificationPreferences: preferences,
            notifications: NotificationCoordinator(center: MockNotificationCenter(), preferences: preferences, defaults: accounts.defaults),
            defaults: accounts.defaults
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
        #expect(window.contentMinSize == NSSize(width: 700, height: 460))

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
