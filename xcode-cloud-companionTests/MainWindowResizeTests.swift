import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MainWindowResizeTests {
    private final class App: ActivationPolicyControlling {
        func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool { true }
        func activate() {}
    }

    private func controller(_ accounts: TestAccounts, frameName: String? = nil) -> MainWindowController {
        MainWindowController(
            accounts: accounts.model, navigation: NavigationModel(), activation: ActivationPolicyCoordinator(app: App(), showsInDock: { true }), openSettings: {},
            frameName: frameName
        )
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    /// The sidebar's foot once made its own height the least height of the whole window: the window grew, and never
    /// came back down. Whatever the foot shows, the window keeps the size it is given, down to its own minimum.
    @Test func whateverTheSidebarShowsTheWindowCanStillBeMadeShort() async throws {
        let accounts = TestAccounts()
        // No reset date: the foot shows the card that asks for it, the tallest thing it can show at rest.
        let personal = try await accounts.add("Personal")
        try await BuildCacheStore(fileURL: personal.paths.buildCache).save(CLIFixture.snapshot)
        await accounts.model.loadCaches()
        let controller = controller(accounts)
        controller.show()
        // Other tests open a main window too: this one is asked for by its controller, not by its title.
        let window = try #require(controller.window)
        defer { window.close() }

        window.setContentSize(MainWindowController.minimumSize)
        try await settle()

        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(content == MainWindowController.minimumSize, "the content did not push the window back up: \(content)")
    }

    /// Left to itself, the hosting controller brought the window down to the least its content can be, 591 × 190.
    @Test func theWindowOpensAtItsSizeAndKeepsTheOneItIsGiven() async throws {
        let controller = controller(TestAccounts())
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }

        try await settle()
        #expect(window.contentRect(forFrameRect: window.frame).size == MainWindowController.openingSize, "opened at \(window.contentRect(forFrameRect: window.frame).size)")

        let chosen = NSSize(width: 1300, height: 820)
        window.setContentSize(chosen)
        try await settle()
        #expect(window.contentRect(forFrameRect: window.frame).size == chosen, "nothing resizes the window behind the user's back")
    }

    @Test func theWindowNeverGetsSmallerThanItsMinimum() async throws {
        let controller = controller(TestAccounts())
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }

        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: MainWindowController.minimumSize)).size
        #expect(window.delegate?.windowWillResize?(window, to: NSSize(width: 100, height: 100)) == minimum)
        #expect(window.delegate?.windowWillResize?(window, to: NSSize(width: 1000, height: 100)) == NSSize(width: 1000, height: minimum.height))
        #expect(window.delegate?.windowWillResize?(window, to: NSSize(width: 1400, height: 900)) == NSSize(width: 1400, height: 900))
    }

    @Test func aFrameSavedTooSmallOpensAtTheMinimum() async throws {
        let name = "MainWindowTest-\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        // What a window that had shrunk to its content's minimum left behind.
        UserDefaults.standard.set("120 120 591 190 0 0 1512 944 ", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let controller = controller(TestAccounts(), frameName: name)
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }

        try await settle()
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(content.width >= MainWindowController.minimumSize.width && content.height >= MainWindowController.minimumSize.height, "opened at \(content)")
    }
}
