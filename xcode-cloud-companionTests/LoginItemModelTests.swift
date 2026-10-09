import Foundation
import ServiceManagement
import Testing
@testable import XcodeCloudCompanion

@MainActor
final class FakeLoginItem: LoginItemControlling {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var refuses = false
    private(set) var openedSystemSettings = false

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if refuses { throw Refused() }
        status = statusAfterRegister
    }

    func unregister() throws {
        if refuses { throw Refused() }
        status = .notRegistered
    }

    func openSystemSettings() {
        openedSystemSettings = true
    }
}

@MainActor
struct LoginItemModelTests {
    @Test func turningOnRegistersTheApp() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        let model = LoginItemModel(loginItem: loginItem)
        #expect(!model.opensAtLogin)

        model.opensAtLogin = true

        #expect(model.opensAtLogin)
        #expect(model.status == .enabled)
    }

    @Test func turningOffUnregistersTheApp() {
        let model = LoginItemModel(loginItem: FakeLoginItem(status: .enabled))

        model.opensAtLogin = false

        #expect(model.status == .notRegistered)
    }

    @Test func approvalPendingIsShownAndLeadsToSystemSettings() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.statusAfterRegister = .requiresApproval
        let model = LoginItemModel(loginItem: loginItem)

        model.opensAtLogin = true
        #expect(model.opensAtLogin)
        #expect(model.requiresApproval)

        model.openSystemSettings()
        #expect(loginItem.openedSystemSettings)
    }

    @Test func changesMadeInSystemSettingsShowUpOnRefresh() {
        let loginItem = FakeLoginItem(status: .enabled)
        let model = LoginItemModel(loginItem: loginItem)

        loginItem.status = .notRegistered
        model.refresh()

        #expect(!model.opensAtLogin)
    }

    @Test func aRefusalIsReportedAndTheToggleFollowsTheRealState() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        loginItem.refuses = true
        let model = LoginItemModel(loginItem: loginItem)

        model.opensAtLogin = true

        #expect(!model.opensAtLogin)
        #expect(model.errorMessage?.contains("Operation not permitted") == true)
    }
}
