import Foundation
import Observation

/// What a row of the Settings sidebar leads to.
nonisolated enum SettingsDestination: Hashable, Sendable {
    case general
    case notifications
    case agents
    case pro
    case account(String)
    case newAccount
}

/// Where the Settings window is: one of its fixed panes, or an account. Picking an account here never changes the one
/// the menu and the main window show: `AccountsSettingsModel` keeps that selection to itself.
@Observable
final class SettingsNavigationModel {
    /// Remembered by name, under the key the tabs used: what a version with tabs stored is still understood.
    enum Pane: String, CaseIterable, Sendable {
        case general, accounts, notifications, agents, pro
    }

    static let storedKey = "settings.selectedTabName"

    let accountsTab: AccountsSettingsModel
    private let defaults: UserDefaults

    var pane: Pane {
        didSet { defaults.set(pane.rawValue, forKey: Self.storedKey) }
    }

    init(accountsTab: AccountsSettingsModel = AccountsSettingsModel(), defaults: UserDefaults = .standard) {
        self.accountsTab = accountsTab
        self.defaults = defaults
        pane = defaults.string(forKey: Self.storedKey).flatMap(Pane.init(rawValue:)) ?? .general
    }

    /// The row of the sidebar that is lit; nil on the accounts' pane while there is no account.
    var destination: SettingsDestination? {
        switch pane {
        case .general: .general
        case .notifications: .notifications
        case .agents: .agents
        case .pro: .pro
        case .accounts:
            switch accountsTab.selection {
            case .account(let id)?: .account(id)
            case .newAccount?: .newAccount
            case nil: nil
            }
        }
    }

    func select(_ destination: SettingsDestination?, among accounts: AccountsModel) {
        switch destination {
        case .general?: pane = .general
        case .notifications?: pane = .notifications
        case .agents?: pane = .agents
        case .pro?: pane = .pro
        case .account(let id)?:
            accountsTab.selection = .account(id)
            pane = .accounts
        case .newAccount?:
            accountsTab.startAdding(among: accounts)
            pane = .accounts
        case nil: break
        }
    }

    /// When the window opens: the new account's form when asked for; an account when there is none yet or when one
    /// lacks its key or its reset date; otherwise the pane used last.
    func open(for accounts: AccountsModel, addingAccount: Bool) {
        accountsTab.prepare(for: accounts, addingAccount: addingAccount)
        if addingAccount || accounts.sessions.isEmpty || accounts.sessions.contains(where: { $0.health.needsAttention }) {
            pane = .accounts
        }
    }

    /// After a removal: the account that took its place is already selected; after the last one, General.
    func accountWasRemoved(from accounts: AccountsModel) {
        if accounts.sessions.isEmpty, pane == .accounts {
            pane = .general
        }
    }
}
