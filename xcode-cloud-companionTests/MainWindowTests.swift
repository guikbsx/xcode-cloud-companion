import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MainWindowTests {
    private final class FakeApp: ActivationPolicyControlling {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
            policies.append(policy)
            return true
        }
        func activate() { activations += 1 }
    }

    @Test func showingTheWindowGivesTheAppADockIconAndClosingItTakesItBack() {
        let app = FakeApp()
        let coordinator = ActivationPolicyCoordinator(app: app, showsInDock: { true })

        coordinator.windowWillShow()
        coordinator.windowDidClose()

        #expect(app.policies == [.regular, .accessory])
        #expect(app.activations == 1)
    }

    @Test func theDockPreferenceKeepsTheAppOutOfTheDock() {
        let app = FakeApp()
        let coordinator = ActivationPolicyCoordinator(app: app, showsInDock: { false })

        coordinator.windowWillShow()

        #expect(app.policies.isEmpty)
        #expect(app.activations == 1)
    }

    @Test func aBuildAddressOpensThatBuildOnAllBuilds() throws {
        let navigation = NavigationModel()
        navigation.sidebarSelection = .overview

        let opened = navigation.open(try #require(URL(string: "cumulus://build/1F0C-22aa")))

        #expect(opened)
        #expect(navigation.selectedBuildID == "1F0C-22aa")
        #expect(navigation.sidebarSelection == .allBuilds)
    }

    @Test(arguments: [
        "cumulus://build", "cumulus://build/", "cumulus://build/a/b", "cumulus://launch/abc", "cumulus://build/abc%2F..%2Fx",
        "https://build/abc", "cumulus://build/a b",
    ])
    func otherAddressesAreIgnored(address: String) {
        let navigation = NavigationModel()

        let opened = URL(string: address).map { navigation.open($0) } ?? false

        #expect(!opened)
        #expect(navigation.selectedBuildID == nil)
    }

    @Test func theAppDeclaresTheCumulusScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])

        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [CumulusURL.scheme])
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }

    @Test func aBuildAddressRoundTrips() throws {
        let url = try #require(CumulusURL.build(id: "abc-123"))

        #expect(CumulusURL.destination(of: url) == .build("abc-123"))
        #expect(CumulusURL.build(id: "../x") == nil)
    }

    @Test func theControllerShowsTheWindowAndGivesTheDockIconBackOnClose() throws {
        let app = FakeApp()
        let controller = MainWindowController(
            buildStore: BuildStore(), usageStore: UsageStore(), settings: SettingsModel(), navigation: NavigationModel(),
            activation: ActivationPolicyCoordinator(app: app, showsInDock: { true }), openSettings: {}
        )

        controller.show()
        let window = try #require(NSApp.windows.first { $0.title == "Cumulus" })
        #expect(window.isVisible)
        #expect(app.policies == [.regular])

        window.close()
        #expect(app.policies == [.regular, .accessory])
    }
}
