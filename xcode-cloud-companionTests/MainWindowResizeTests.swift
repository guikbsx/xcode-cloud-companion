import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MainWindowResizeTests {
    private final class App: ActivationPolicyControlling {
        func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool { true }
        func activate() {}
    }

    /// The sidebar's foot once made its own height the least height of the whole window: the window grew, and never
    /// came back down. Whatever the foot shows, the window must still be allowed to be short.
    @Test func whateverTheSidebarShowsTheWindowCanStillBeMadeShort() async throws {
        let accounts = TestAccounts()
        // No reset date: the foot shows the card that asks for it, the tallest thing it can show at rest.
        let personal = try await accounts.add("Personal")
        try await BuildCacheStore(fileURL: personal.paths.buildCache).save(CLIFixture.snapshot)
        await accounts.model.loadCaches()
        let controller = MainWindowController(
            accounts: accounts.model, navigation: NavigationModel(), activation: ActivationPolicyCoordinator(app: App(), showsInDock: { true }), openSettings: {}
        )
        controller.show()
        let window = try #require(NSApp.windows.first { $0.title == "Cumulus" })
        defer { window.close() }

        window.setContentSize(NSSize(width: 1100, height: 800))
        try await Task.sleep(for: .milliseconds(700))

        #expect(window.contentMinSize.height < 400, "the least content height is \(window.contentMinSize.height)")
    }
}
