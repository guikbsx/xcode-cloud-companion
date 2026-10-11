import Foundation
import Observation

/// How an account stands, for its line in the Accounts tab: what to fix first when something is missing.
nonisolated enum AccountHealth: Equatable, Sendable {
    case connected
    case missingKey
    /// Apple refused the key on the last sync: revoked, or a wrong Issuer ID.
    case keyRefused
    case missingResetDate

    static func of(hasKey: Bool, lastError: AppStoreConnectError?, hasResetDate: Bool) -> AccountHealth {
        guard hasKey else { return .missingKey }
        switch lastError {
        case .unauthorized?, .invalidPrivateKey?: return .keyRefused
        default: break
        }
        return hasResetDate ? .connected : .missingResetDate
    }

    var needsAttention: Bool {
        self != .connected
    }

    var label: String {
        switch self {
        case .connected: String(localized: "Connected", comment: "State of an account in Settings: its key works.")
        case .missingKey: String(localized: "No API key")
        case .keyRefused: String(localized: "Key refused", comment: "State of an account in Settings: App Store Connect refused its key.")
        case .missingResetDate: String(localized: "Reset date missing")
        }
    }
}

extension AccountSession {
    var health: AccountHealth {
        .of(hasKey: settings.hasStoredKey, lastError: buildStore.lastError, hasResetDate: settings.resetAnchor != nil)
    }
}

/// An account being added. Nothing exists until Apple accepts its key: then the account is made, its key goes into the
/// keychain, and the form is gone.
@Observable
final class NewAccountModel {
    var name: String
    var issuerID = ""
    var keyID = ""
    var keyAccess = KeyAccess.defaultValue
    private(set) var keyFileName: String?
    /// The key file could not be read, or the keychain refused it.
    private(set) var errorMessage: String?
    /// Apple's answer when it refused the key.
    private(set) var refusal: String?
    private(set) var isTesting = false
    private var privateKeyPEM: String?
    private let makeClient: (AppStoreConnectCredentials) -> AppStoreConnectClient

    init(name: String, makeClient: @escaping (AppStoreConnectCredentials) -> AppStoreConnectClient = { AppStoreConnectClient(credentials: $0) }) {
        self.name = name
        self.makeClient = makeClient
    }

    var canSave: Bool {
        issuerID.nilIfBlank != nil && keyID.nilIfBlank != nil && privateKeyPEM != nil && !isTesting
    }

    func importPrivateKey(from url: URL) {
        guard let pem = SettingsModel.readPrivateKey(at: url) else {
            errorMessage = AppStoreConnectError.invalidPrivateKey.message
            return
        }
        privateKeyPEM = pem
        keyFileName = url.lastPathComponent
        errorMessage = nil
        if keyID.nilIfBlank == nil, let inferred = SettingsModel.keyID(fromFileName: url.lastPathComponent) {
            keyID = inferred
        }
    }

    /// Tests the key with Apple, then makes the account. Nil while Apple, or the keychain, refuses.
    func save(into accounts: AccountsModel) async -> AccountSession? {
        guard canSave, let pem = privateKeyPEM, let issuerID = issuerID.nilIfBlank, let keyID = keyID.nilIfBlank else { return nil }
        let stored = StoredCredentials(issuerID: issuerID, keyID: keyID, privateKeyPEM: pem)
        isTesting = true
        refusal = nil
        errorMessage = nil
        defer { isTesting = false }
        let products: [CIProduct]
        do {
            products = try await makeClient(try stored.credentials()).products()
        } catch {
            refusal = error.message
            return nil
        }
        do {
            return try await accounts.add(name: name, credentials: stored, keyAccess: keyAccess, productNames: products.map { $0.appName ?? $0.name })
        } catch {
            errorMessage = error.message
            return nil
        }
    }
}

/// What the Accounts tab shows: the account picked in its list, or a new account's form. Picking an account here never
/// changes the one the menu and the window show.
@Observable
final class AccountsSettingsModel {
    enum Selection: Hashable {
        case account(String)
        case newAccount
    }

    var selection: Selection?
    private(set) var newAccount: NewAccountModel?
    private var beforeAdding: Selection?
    private let makeClient: (AppStoreConnectCredentials) -> AppStoreConnectClient

    init(makeClient: @escaping (AppStoreConnectCredentials) -> AppStoreConnectClient = { AppStoreConnectClient(credentials: $0) }) {
        self.makeClient = makeClient
    }

    var selectedAccountID: String? {
        if case .account(let id) = selection { id } else { nil }
    }

    /// When Settings open: the new account's form when asked for, otherwise the first account that needs something,
    /// otherwise the one picked before, otherwise the one on screen.
    func prepare(for accounts: AccountsModel, addingAccount: Bool) {
        if addingAccount {
            startAdding(among: accounts)
            return
        }
        if selection == .newAccount, newAccount != nil { return }
        if let first = accounts.sessions.first(where: { $0.health.needsAttention }) {
            selection = .account(first.id)
            return
        }
        if let id = selectedAccountID, accounts.session(id: id) != nil { return }
        selection = (accounts.selectedID ?? accounts.sessions.first?.id).map(Selection.account)
    }

    /// A form already started is taken up where it was left.
    func startAdding(among accounts: AccountsModel) {
        if selection != .newAccount {
            beforeAdding = selection
        }
        if newAccount == nil {
            newAccount = NewAccountModel(name: AccountsModel.defaultName(among: accounts.sessions.map(\.name)), makeClient: makeClient)
        }
        selection = .newAccount
    }

    /// Nothing of the form is kept.
    func cancelAdding(among accounts: AccountsModel) {
        newAccount = nil
        if case .account(let id)? = beforeAdding, accounts.session(id: id) != nil {
            selection = beforeAdding
        } else {
            selection = accounts.sessions.first.map { .account($0.id) }
        }
    }

    func saveNewAccount(into accounts: AccountsModel) async {
        guard let form = newAccount, let session = await form.save(into: accounts) else { return }
        newAccount = nil
        selection = .account(session.id)
    }

    /// After a removal: the account that took its place in the list, or nothing after the last one.
    func remove(_ id: String, from accounts: AccountsModel) async {
        let index = accounts.sessions.firstIndex { $0.id == id } ?? 0
        guard await accounts.remove(id) else { return }
        if selectedAccountID == id || selection == nil {
            selection = accounts.sessions.isEmpty ? nil : .account(accounts.sessions[min(index, accounts.sessions.count - 1)].id)
        }
    }
}
