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

    @Test func theWindowGrowsButNeverShrinksBelowTheTabItShows() async throws {
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

        #expect(window.styleMask.contains(.resizable))
        // Without an account, Settings open on Accounts, the widest tab.
        for _ in 0..<50 where tabs.selectedTabViewItemIndex != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tabs.selectedTabViewItemIndex == 1 && window.contentMinSize == NSSize(width: 780, height: 720))

        // The user widens the Accounts tab; another tab opens at its own size all the same.
        window.setContentSize(NSSize(width: 1000, height: 800))
        tabs.selectedTabViewItemIndex = 0
        #expect(window.contentMinSize == NSSize(width: 560, height: 400))
        for _ in 0..<100 where window.contentLayoutRect.size != NSSize(width: 560, height: 400) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.contentLayoutRect.size == NSSize(width: 560, height: 400))
        tabs.selectedTabViewItemIndex = 3
        #expect(window.contentMinSize == NSSize(width: 560, height: 700))
    }
}
