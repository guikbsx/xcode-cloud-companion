import CryptoKit
import Foundation
import Synchronization
@testable import XcodeCloudCompanion

enum Fixture {
    struct Missing: Error {
        let name: String
    }

    static func data(_ name: String) throws -> Data {
        try load(name, withExtension: "json")
    }

    static func csv(_ name: String) throws -> Data {
        try load(name, withExtension: "csv")
    }

    /// The lines of an anonymised excerpt of a real Xcode Cloud log, with the timestamp prefix they have in the archive.
    static func logLines(_ name: String) throws -> [String] {
        var lines = String(decoding: try load("log-\(name)", withExtension: "log"), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func logURL(_ name: String) throws -> URL {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "log-\(name)", withExtension: "log") else { throw Missing(name: name) }
        return url
    }

    private static func load(_ name: String, withExtension fileExtension: String) throws -> Data {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: fileExtension) else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }
}

private final class BundleToken {}

extension AppStoreConnectCredentials {
    static func sample(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> AppStoreConnectCredentials {
        AppStoreConnectCredentials(issuerID: "issuer-123", keyID: "KEY123", privateKey: privateKey)
    }
}

final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date) {
        self.date = Mutex(date)
    }

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0.addTimeInterval(seconds) }
    }
}

actor MockTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError?
        var headers: [String: String] = [:]
    }

    private(set) var requests: [URLRequest] = []
    private let reply: @Sendable (URLRequest) -> Reply

    init(reply: @escaping @Sendable (URLRequest) -> Reply) {
        self.reply = reply
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = reply(request)
        if let error = reply.error {
            throw error
        }
        let response = HTTPURLResponse(url: request.url ?? URL(filePath: "/"), statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)
        return (reply.body, response ?? URLResponse())
    }
}

extension URLRequest {
    func queryValue(_ name: String) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// Accounts that live in a temporary folder and in their own preferences: no keychain, no network, nothing of the real app.
@MainActor
final class TestAccounts {
    let root: URL
    let defaults: UserDefaults
    let registryStore: AccountRegistryStore
    /// The keychain of each account made so far, by account id.
    private(set) var credentials: [String: InMemoryCredentialsStore] = [:]
    /// The webhook address of each account made so far, by account id: a keychain item of its own, in memory.
    private(set) var webhookAddresses: [String: InMemoryWebhookAddressStore] = [:]
    /// What stands in for Apple: offline unless a test says otherwise, so no account ever reaches the network.
    var transport = MockTransport { _ in MockTransport.Reply(error: URLError(.notConnectedToInternet)) }
    private(set) lazy var model = makeModel()

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "cumulus-accounts-\(UUID().uuidString)")
        let suiteName = "TestAccounts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        registryStore = AccountRegistryStore(fileURL: root.appending(path: "Accounts.json"))
    }

    static let credentials = StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "pem")

    /// An account as Settings add it once Apple accepted its key; the first one is shown at once.
    @discardableResult
    func add(_ name: String, credentials: StoredCredentials = TestAccounts.credentials) async throws -> AccountSession {
        try await model.add(name: name, credentials: credentials)
    }

    /// An account's keychain, made before the account when a test needs a key already there.
    func keychain(_ accountID: String) -> InMemoryCredentialsStore {
        if let store = credentials[accountID] { return store }
        let store = InMemoryCredentialsStore()
        credentials[accountID] = store
        return store
    }

    func webhookStore(_ accountID: String) -> InMemoryWebhookAddressStore {
        if let store = webhookAddresses[accountID] { return store }
        let store = InMemoryWebhookAddressStore()
        webhookAddresses[accountID] = store
        return store
    }

    func paths(_ accountID: String) -> AccountPaths {
        AccountPaths(accountID: accountID, supportRoot: root.appending(path: "Support"), cachesRoot: root.appending(path: "Caches"))
    }

    /// Another model over the same folder and preferences, as after a restart of the app.
    func makeModel(migration: AccountMigration? = nil, watchedDirectory: URL? = nil) -> AccountsModel {
        AccountsModel(registryStore: registryStore, defaults: defaults, migration: migration, watchedDirectory: watchedDirectory) { [self] account in
            session(account)
        }
    }

    private func session(_ account: Account) -> AccountSession {
        let paths = paths(account.id)
        let store = keychain(account.id)
        let buildStore = BuildStore(
            credentialsStore: store, cacheStore: BuildCacheStore(fileURL: paths.buildCache),
            makeClient: { [transport] in AppStoreConnectClient(credentials: $0, transport: transport) }
        )
        return AccountSession(
            account: account, paths: paths,
            settings: SettingsModel(accountID: account.id, store: store, defaults: defaults, planMirror: SharedPlanStore(fileURL: paths.usagePlan)),
            buildStore: buildStore,
            usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(cache: BuildExtrasCache(directory: paths.buildDetails), client: { [buildStore] in await buildStore.detailClient() }),
            defaults: defaults,
            webhookAddresses: webhookStore(account.id)
        )
    }
}
