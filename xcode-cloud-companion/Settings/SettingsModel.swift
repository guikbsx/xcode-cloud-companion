import Foundation
import Observation

@Observable
final class SettingsModel {
    enum ConnectionState: Equatable {
        case idle
        case testing
        case connected(productNames: [String])
        case failed(String)
    }

    enum KeyState: Equatable {
        case none
        case imported(fileName: String)
        case stored
    }

    var issuerID = ""
    var keyID = ""
    private(set) var keyState = KeyState.none
    private(set) var connectionState = ConnectionState.idle
    private(set) var errorMessage: String?
    @ObservationIgnored var onCredentialsChange: (() -> Void)?
    /// Called once the key is gone, to wipe what was read with it (imported usage exports).
    @ObservationIgnored var onReset: (() async -> Void)?

    var planHours: Int {
        didSet {
            defaults.set(planHours, forKey: key(AccountDefaults.planHours))
            mirrorPlan()
        }
    }

    var resetAnchor: Date? {
        didSet {
            defaults.set(resetAnchor, forKey: key(AccountDefaults.resetAnchor))
            mirrorPlan()
        }
    }

    /// What the key may do: the user says so here, and the first 403 from Apple switches it to read only.
    var keyAccess: KeyAccess {
        didSet { defaults.set(keyAccess.rawValue, forKey: key(AccountDefaults.keyAccess)) }
    }

    let accountID: String

    private var importedPrivateKeyPEM: String?
    private let store: any CredentialsStore
    private let defaults: UserDefaults
    private let makeClient: (AppStoreConnectCredentials) -> AppStoreConnectClient
    private let now: () -> Date
    private let planMirror: SharedPlanStore?
    private var planMirrorWrite: Task<Void, Never>?

    init(
        accountID: String = AccountRegistry.firstAccountID,
        store: any CredentialsStore = KeychainCredentialsStore(),
        defaults: UserDefaults = .standard,
        planMirror: SharedPlanStore? = nil,
        makeClient: @escaping (AppStoreConnectCredentials) -> AppStoreConnectClient = { AppStoreConnectClient(credentials: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.defaults = defaults
        self.makeClient = makeClient
        self.now = now
        self.planMirror = planMirror
        self.accountID = accountID
        let storedHours = defaults.integer(forKey: AccountDefaults.key(AccountDefaults.planHours, accountID: accountID))
        planHours = UsagePlan.availableHours.contains(storedHours) ? storedHours : UsagePlan.defaultHours
        resetAnchor = defaults.object(forKey: AccountDefaults.key(AccountDefaults.resetAnchor, accountID: accountID)) as? Date
        keyAccess = KeyAccess.stored(in: defaults, accountID: accountID)
    }

    private func key(_ name: String) -> String {
        AccountDefaults.key(name, accountID: accountID)
    }

    var plan: UsagePlan? {
        resetAnchor.map { UsagePlan(hours: planHours, resetAnchor: $0) }
    }

    /// Copies the plan where the `cumulus` command reads it; writes follow one another so the last change wins.
    func mirrorPlan() {
        guard let planMirror else { return }
        let plan = plan
        let previous = planMirrorWrite
        planMirrorWrite = Task {
            await previous?.value
            await planMirror.save(plan)
        }
    }

    /// The date picker shows the upcoming reset; editing it moves the anchor.
    var nextReset: Date {
        get { plan?.nextReset(after: now()) ?? Self.suggestedReset(after: now()) }
        set { resetAnchor = newValue }
    }

    var canSave: Bool {
        !issuerID.trimmed.isEmpty && !keyID.trimmed.isEmpty && importedPrivateKeyPEM != nil
    }

    var hasStoredKey: Bool {
        keyState == .stored
    }

    func load() async {
        do {
            guard let stored = try await store.load() else { return }
            issuerID = stored.issuerID
            keyID = stored.keyID
            keyState = .stored
        } catch {
            errorMessage = error.message
        }
    }

    func importPrivateKey(from url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        guard let pem = try? String(contentsOf: url, encoding: .utf8),
              (try? AppStoreConnectCredentials(issuerID: "", keyID: "", privateKeyPEM: pem)) != nil
        else {
            errorMessage = AppStoreConnectError.invalidPrivateKey.message
            return
        }
        importedPrivateKeyPEM = pem
        keyState = .imported(fileName: url.lastPathComponent)
        errorMessage = nil
        if keyID.trimmed.isEmpty, let inferred = Self.keyID(fromFileName: url.lastPathComponent) {
            keyID = inferred
        }
    }

    func saveAndTestConnection() async {
        guard canSave, let pem = importedPrivateKeyPEM else { return }
        let credentials = StoredCredentials(issuerID: issuerID.trimmed, keyID: keyID.trimmed, privateKeyPEM: pem)
        do {
            try await store.save(credentials)
        } catch {
            errorMessage = error.message
            return
        }
        importedPrivateKeyPEM = nil
        keyState = .stored
        errorMessage = nil
        onCredentialsChange?()
        await testConnection(with: credentials)
    }

    func testConnection() async {
        do {
            guard let stored = try await store.load() else {
                keyState = .none
                return
            }
            await testConnection(with: stored)
        } catch {
            connectionState = .failed(error.message)
        }
    }

    /// Starts over: the key leaves the keychain, then everything read or entered with it goes (builds, imported
    /// usage, plan). If the keychain refuses, nothing else is touched, so the app never half forgets an account.
    @discardableResult
    func removeKey() async -> Bool {
        do {
            try await store.delete()
        } catch {
            errorMessage = error.message
            return false
        }
        issuerID = ""
        keyID = ""
        importedPrivateKeyPEM = nil
        keyState = .none
        connectionState = .idle
        errorMessage = nil
        planHours = UsagePlan.defaultHours
        resetAnchor = nil
        keyAccess = .defaultValue
        AccountDefaults.removeAll(accountID: accountID, from: defaults)
        onCredentialsChange?()
        await onReset?()
        return true
    }

    private func testConnection(with stored: StoredCredentials) async {
        connectionState = .testing
        do {
            let client = makeClient(try stored.credentials())
            let products = try await client.products()
            connectionState = .connected(productNames: products.map { $0.appName ?? $0.name })
        } catch {
            connectionState = .failed(error.message)
        }
    }

    // MARK: - Helpers

    static func keyID(fromFileName fileName: String) -> String? {
        let name = (fileName as NSString).deletingPathExtension
        guard name.hasPrefix("AuthKey_") else { return nil }
        let keyID = String(name.dropFirst("AuthKey_".count))
        return keyID.isEmpty ? nil : keyID
    }

    static func suggestedReset(after date: Date, calendar: Calendar = .current) -> Date {
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) ?? date
        return calendar.dateInterval(of: .minute, for: nextMonth)?.start ?? nextMonth
    }

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
