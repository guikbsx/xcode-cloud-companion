import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

final class InMemoryCredentialsStore: CredentialsStore {
    private let stored: Mutex<StoredCredentials?>

    init(_ credentials: StoredCredentials? = nil) {
        stored = Mutex(credentials)
    }

    var current: StoredCredentials? {
        stored.withLock { $0 }
    }

    func load() async throws(CredentialsStoreError) -> StoredCredentials? {
        current
    }

    func save(_ credentials: StoredCredentials) async throws(CredentialsStoreError) {
        stored.withLock { $0 = credentials }
    }

    func delete() async throws(CredentialsStoreError) {
        stored.withLock { $0 = nil }
    }
}

/// A keychain that holds a key but refuses to delete it.
final class RefusingCredentialsStore: CredentialsStore {
    func load() async throws(CredentialsStoreError) -> StoredCredentials? {
        StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "pem")
    }

    func save(_ credentials: StoredCredentials) async throws(CredentialsStoreError) {}

    func delete() async throws(CredentialsStoreError) {
        throw .keychain(errSecAuthFailed)
    }
}

@MainActor
struct SettingsModelTests {
    private let defaults: UserDefaults
    private let pem = P256.Signing.PrivateKey().pemRepresentation

    init() {
        let suiteName = "SettingsModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(
        store: InMemoryCredentialsStore = InMemoryCredentialsStore(),
        reply: @escaping @Sendable (URLRequest) -> MockTransport.Reply = { _ in
            MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data())
        }
    ) -> SettingsModel {
        let transport = MockTransport(reply: reply)
        return SettingsModel(store: store, defaults: defaults, makeClient: { AppStoreConnectClient(credentials: $0, transport: transport) })
    }

    private func writeKeyFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importingAKeyFileFillsTheKeyIDFromItsName() throws {
        let model = makeModel()
        let url = try writeKeyFile(named: "AuthKey_ABC123XYZ.p8", contents: pem)

        model.importPrivateKey(from: url)

        #expect(model.keyID == "ABC123XYZ")
        #expect(model.keyState == .imported(fileName: url.lastPathComponent))
        #expect(model.errorMessage == nil)
    }

    @Test func keyIDIsInferredOnlyFromApplesFileName() {
        #expect(SettingsModel.keyID(fromFileName: "AuthKey_ABC123.p8") == "ABC123")
        #expect(SettingsModel.keyID(fromFileName: "my-key.p8") == nil)
        #expect(SettingsModel.keyID(fromFileName: "AuthKey_.p8") == nil)
    }

    @Test func anInvalidKeyFileIsRefused() throws {
        let model = makeModel()
        let url = try writeKeyFile(named: "AuthKey_ABC.p8", contents: "not a key")

        model.importPrivateKey(from: url)

        #expect(model.keyState == .none)
        #expect(model.errorMessage != nil)
        #expect(!model.canSave)
    }

    @Test func savingStoresTheKeyThenTestsTheConnection() async throws {
        let store = InMemoryCredentialsStore()
        let model = makeModel(store: store)
        model.issuerID = "  issuer-1 "
        model.importPrivateKey(from: try writeKeyFile(named: "AuthKey_KEY1.p8", contents: pem))
        #expect(model.canSave)

        await model.saveAndTestConnection()

        #expect(store.current == StoredCredentials(issuerID: "issuer-1", keyID: "KEY1", privateKeyPEM: pem))
        #expect(model.keyState == .stored)
        #expect(model.connectionState == .connected(productNames: ["Sample App Store Name", "Sample Framework"]))
    }

    @Test func aRefusedKeyIsReportedReadably() async throws {
        let store = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem))
        let model = makeModel(store: store) { _ in MockTransport.Reply(status: 401) }

        await model.testConnection()

        #expect(model.connectionState == .failed(AppStoreConnectError.unauthorized(status: 401).message))
    }

    @Test func loadingShowsTheStoredIdentifiersButNeverTheKey() async {
        let store = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem))
        let model = makeModel(store: store)

        await model.load()

        #expect(model.issuerID == "issuer")
        #expect(model.keyID == "KEY")
        #expect(model.keyState == .stored)
        #expect(!model.canSave)
    }

    @Test func removingTheKeyClearsTheKeychainAndTheForm() async {
        let store = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem))
        let model = makeModel(store: store)
        await model.load()

        await model.removeKey()

        #expect(store.current == nil)
        #expect(model.issuerID.isEmpty && model.keyID.isEmpty)
        #expect(model.keyState == .none)
    }

    @Test func removingTheKeyStartsOverWithThePlanAndTheImportedUsage() async {
        let store = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem))
        let model = makeModel(store: store)
        await model.load()
        model.planHours = 100
        model.resetAnchor = Date(timeIntervalSince1970: 1_794_059_280)
        var wiped = false
        model.onReset = { wiped = true }

        await model.removeKey()

        #expect(wiped)
        #expect(model.planHours == UsagePlan.defaultHours)
        #expect(model.resetAnchor == nil)
        #expect(makeModel().resetAnchor == nil)
    }

    @Test func aKeychainRefusalLeavesEverythingInPlaceAndSaysWhy() async {
        let model = SettingsModel(store: RefusingCredentialsStore(), defaults: defaults)
        await model.load()
        model.resetAnchor = Date(timeIntervalSince1970: 1_794_059_280)
        var wiped = false
        model.onReset = { wiped = true }

        await model.removeKey()

        #expect(!wiped)
        #expect(model.resetAnchor != nil)
        #expect(model.keyState == .stored)
        #expect(model.errorMessage?.contains("-25293") == true)
    }

    @Test func aKeySavedByAnotherBuildSaysWhereToDeleteIt() {
        let message = CredentialsStoreError.keychain(errSecInvalidOwnerEdit).message

        #expect(message.contains(KeychainCredentialsStore.defaultService))
        #expect(message.contains("Keychain Access"))
    }

    @Test func planDefaultsToTwentyFiveHoursAndPersists() {
        let model = makeModel()
        #expect(model.planHours == 25)
        #expect(model.resetAnchor == nil)

        let reset = Date(timeIntervalSince1970: 1_794_059_280)
        model.planHours = 100
        model.nextReset = reset

        let reloaded = makeModel()
        #expect(reloaded.planHours == 100)
        #expect(reloaded.resetAnchor == reset)
        #expect(reloaded.plan == UsagePlan(hours: 100, resetAnchor: reset))
    }

    @Test func storedCredentialsNeverPrintTheirKey() {
        let stored = StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem)

        #expect(!String(describing: stored).contains("PRIVATE KEY"))
        #expect(!String(reflecting: stored).contains("PRIVATE KEY"))
    }
}

@MainActor
struct KeyAccessTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "KeyAccessTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func withoutAChoiceTheKeyIsTakenToLaunchBuilds() {
        #expect(KeyAccess.defaultValue == .canLaunch)
        #expect(KeyAccess.current(in: defaults) == .canLaunch)
    }

    @Test func aChoiceAlreadyMadeIsKeptIncludingARefusalByApple() {
        // What a 403 writes, and what the picker writes.
        defaults.set(KeyAccess.readOnly.rawValue, forKey: KeyAccess.defaultsKey)
        #expect(KeyAccess.current(in: defaults) == .readOnly)

        defaults.set(KeyAccess.canLaunch.rawValue, forKey: KeyAccess.defaultsKey)
        #expect(KeyAccess.current(in: defaults) == .canLaunch)

        defaults.set("somethingElse", forKey: KeyAccess.defaultsKey)
        #expect(KeyAccess.current(in: defaults) == .canLaunch)
    }

    @Test func removingTheKeyPutsTheAccessBackToItsDefault() async {
        defaults.set(KeyAccess.readOnly.rawValue, forKey: KeyAccess.defaultsKey)
        let store = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "pem"))
        let model = SettingsModel(store: store, defaults: defaults)

        await model.removeKey()

        #expect(defaults.object(forKey: KeyAccess.defaultsKey) == nil)
        #expect(KeyAccess.current(in: defaults) == .canLaunch)
    }

    @Test func aKeychainThatRefusesLeavesTheAccessAlone() async {
        defaults.set(KeyAccess.readOnly.rawValue, forKey: KeyAccess.defaultsKey)
        let model = SettingsModel(store: RefusingCredentialsStore(), defaults: defaults)

        await model.removeKey()

        #expect(KeyAccess.current(in: defaults) == .readOnly)
    }
}

struct KeychainCredentialsStoreTests {
    @Test func credentialsRoundTripThroughTheKeychain() async throws {
        let store = KeychainCredentialsStore(service: "com.guik.xcode-cloud-companion.tests.\(UUID().uuidString)")
        let credentials = StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "pem")
        defer { Task { try? await store.delete() } }

        #expect(try await store.load() == nil)
        try await store.save(credentials)
        #expect(try await store.load() == credentials)

        var updated = credentials
        updated.keyID = "KEY2"
        try await store.save(updated)
        #expect(try await store.load() == updated)

        try await store.delete()
        #expect(try await store.load() == nil)
    }
}
