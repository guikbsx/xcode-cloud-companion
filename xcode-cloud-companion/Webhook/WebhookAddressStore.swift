import Foundation
import Security
import Synchronization

/// Where an account's webhook address is kept. It is a secret: a keychain item of its own, never a preference.
nonisolated protocol WebhookAddressStore: Sendable {
    func load() async throws(CredentialsStoreError) -> String?
    func save(_ address: String) async throws(CredentialsStoreError)
    func delete() async throws(CredentialsStoreError)
}

/// One generic-password item for each account, under a service of its own: the account's id is `kSecAttrAccount`, as for its key.
nonisolated struct KeychainWebhookAddressStore: WebhookAddressStore {
    static let defaultService = "com.guik.xcode-cloud-companion.webhook-address"

    var service = defaultService
    var account: String

    @concurrent func load() async throws(CredentialsStoreError) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let address = String(data: data, encoding: .utf8) else { throw .corruptedItem }
            return address
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    @concurrent func save(_ address: String) async throws(CredentialsStoreError) {
        let data = Data(address.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Cumulus — webhook address"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw .keychain(addStatus) }
        default:
            throw .keychain(updateStatus)
        }
    }

    @concurrent func delete() async throws(CredentialsStoreError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// An address held in memory only: what an account has until it is given a keychain, so that nothing reaches the real one by accident.
nonisolated final class InMemoryWebhookAddressStore: WebhookAddressStore {
    private let stored: Mutex<String?>

    init(_ address: String? = nil) {
        stored = Mutex(address)
    }

    var current: String? {
        stored.withLock { $0 }
    }

    func load() async throws(CredentialsStoreError) -> String? {
        current
    }

    func save(_ address: String) async throws(CredentialsStoreError) {
        stored.withLock { $0 = address }
    }

    func delete() async throws(CredentialsStoreError) {
        stored.withLock { $0 = nil }
    }
}
