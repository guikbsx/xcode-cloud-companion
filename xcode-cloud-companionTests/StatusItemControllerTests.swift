import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct StatusItemControllerTests {
    @Test func installsAStatusItemWithAnIcon() {
        let controller = StatusItemController()

        #expect(controller.statusItem.button?.image != nil)
    }

    @Test func menuLetsTheUserQuit() {
        let controller = StatusItemController()

        let quitItem = controller.statusItem.menu?.items.first {
            $0.action == #selector(NSApplication.terminate(_:))
        }
        #expect(quitItem?.keyEquivalent == "q")
    }

    @Test func appStaysOutOfTheDock() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }
}
