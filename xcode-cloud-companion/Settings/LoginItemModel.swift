import Foundation
import Observation
import ServiceManagement

protocol LoginItemControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct MainAppLoginItem: LoginItemControlling {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@Observable
final class LoginItemModel {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?
    private let loginItem: any LoginItemControlling

    init(loginItem: any LoginItemControlling = MainAppLoginItem()) {
        self.loginItem = loginItem
        status = loginItem.status
    }

    /// Waiting for the user's approval still counts as on: the system will open the app once approved.
    var opensAtLogin: Bool {
        get { status == .enabled || status == .requiresApproval }
        set { setOpensAtLogin(newValue) }
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    func refresh() {
        status = loginItem.status
    }

    func openSystemSettings() {
        loginItem.openSystemSettings()
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "macOS refused the change: \(error.localizedDescription)")
        }
        refresh()
    }
}
