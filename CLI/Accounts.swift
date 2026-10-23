import Foundation

/// One App Store Connect team the app follows. Its API key is in the keychain, under the account's id.
nonisolated struct Account: Codable, Sendable, Equatable, Identifiable {
    var id: String
    /// Chosen by the user; the `cumulus` command takes it as `--account`.
    var name: String

    /// Ids name folders, keychain items and preference keys: letters, digits and dashes only.
    static func isValid(id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// The accounts, and the one the menu, the window and the `cumulus` command show. None at all until a key is added.
nonisolated struct AccountRegistry: Codable, Sendable, Equatable {
    /// What an installation from before accounts existed becomes: its keychain item already carries this id.
    static let firstAccountID = "default"
    static let empty = AccountRegistry(accounts: [], selectedID: nil)

    private(set) var accounts: [Account]
    /// Nil only without accounts.
    private(set) var selectedID: String?

    /// Accounts whose id is not usable are left out; the selection falls back on the first account.
    init(accounts: [Account], selectedID: String?) {
        var seen: Set<String> = []
        let usable = accounts.filter { Account.isValid(id: $0.id) && seen.insert($0.id).inserted }
        self.accounts = usable
        self.selectedID = usable.contains { $0.id == selectedID } ? selectedID : usable.first?.id
    }

    init(first name: String) {
        accounts = [Account(id: Self.firstAccountID, name: name)]
        selectedID = Self.firstAccountID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accounts = try container.decode([Account].self, forKey: .accounts)
        let selectedID = try container.decodeIfPresent(String.self, forKey: .selectedID)
        self = AccountRegistry(accounts: accounts, selectedID: selectedID)
    }

    var selected: Account? {
        accounts.first { $0.id == selectedID }
    }

    func account(id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    /// Accounts by id, or by name whatever the case: a name may be worn by more than one.
    func accounts(matching reference: String) -> [Account] {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let exact = account(id: wanted) {
            return [exact]
        }
        return accounts.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    mutating func select(_ id: String) {
        if account(id: id) != nil {
            selectedID = id
        }
    }

    mutating func add(_ account: Account) {
        guard Account.isValid(id: account.id), self.account(id: account.id) == nil else { return }
        accounts.append(account)
        if selectedID == nil {
            selectedID = account.id
        }
    }

    mutating func rename(_ id: String, to name: String) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].name = name
        }
    }

    /// The selection goes to the account that took its place, or to none after the last one. Returns whether the account went.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        accounts.remove(at: index)
        if selectedID == id {
            selectedID = accounts.isEmpty ? nil : accounts[min(index, accounts.count - 1)].id
        }
        return true
    }
}

/// The registry lives in the app group container: the app writes it, the `cumulus` command reads it.
nonisolated struct AccountRegistryStore: Sendable {
    var fileURL: URL = SharedContainer.applicationSupport.appending(path: "Accounts.json")

    @concurrent func load() async -> AccountRegistry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AccountRegistry.self, from: data)
    }

    @concurrent func save(_ registry: AccountRegistry) async {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(registry).write(to: fileURL, options: [.atomic])
    }
}

/// Where one account keeps what was read with its key: nothing is shared between two accounts, so one goes without a trace in the others.
nonisolated struct AccountPaths: Sendable, Equatable {
    static let folderName = "Accounts"
    static let first = AccountPaths(accountID: AccountRegistry.firstAccountID)

    /// In the app group container, where the `cumulus` command reads.
    var support: URL
    /// In the app's own caches: what can be fetched again.
    var caches: URL

    init(accountID: String, supportRoot: URL = SharedContainer.applicationSupport, cachesRoot: URL = .cachesDirectory) {
        support = supportRoot.appending(path: Self.folderName).appending(path: accountID, directoryHint: .isDirectory)
        caches = cachesRoot.appending(path: Self.folderName).appending(path: accountID, directoryHint: .isDirectory)
    }

    var buildCache: URL { support.appending(path: "BuildCache.json") }
    var usageLedger: URL { support.appending(path: "UsageLedger.json") }
    var usagePlan: URL { support.appending(path: "UsagePlan.json") }
    var buildDetails: URL { support.appending(path: "BuildDetails") }
    var workflowDetails: URL { support.appending(path: "WorkflowDetails") }
    var failureInsights: URL { support.appending(path: "FailureInsights") }
    var testFlight: URL { support.appending(path: "TestFlight.json") }
    var testFlightGroups: URL { support.appending(path: "TestFlightGroups.json") }
    var appIcons: URL { caches.appending(path: "AppIcons") }
    var logs: URL { caches.appending(path: "Logs") }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: caches)
    }
}
