import Foundation
import Security

nonisolated struct StoredCredentials: Codable, Sendable, Equatable {
    var issuerID: String
    var keyID: String
    var privateKeyPEM: String

    func credentials() throws(AppStoreConnectError) -> AppStoreConnectCredentials {
        try AppStoreConnectCredentials(issuerID: issuerID, keyID: keyID, privateKeyPEM: privateKeyPEM)
    }
}

extension StoredCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    nonisolated var description: String { "StoredCredentials(keyID: \(keyID), privateKeyPEM: <redacted>)" }
    nonisolated var debugDescription: String { description }
}

nonisolated enum CredentialsStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corruptedItem
}

nonisolated protocol CredentialsStore: Sendable {
    func load() async throws(CredentialsStoreError) -> StoredCredentials?
    func save(_ credentials: StoredCredentials) async throws(CredentialsStoreError)
    func delete() async throws(CredentialsStoreError)
}

/// One generic-password item holds the whole credential set, so it is written and removed atomically.
nonisolated struct KeychainCredentialsStore: CredentialsStore {
    static let defaultService = "com.guik.xcode-cloud-companion.app-store-connect-api-key"

    var service = defaultService
    var account = "default"

    @concurrent func load() async throws(CredentialsStoreError) -> StoredCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data)
            else { throw .corruptedItem }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    @concurrent func save(_ credentials: StoredCredentials) async throws(CredentialsStoreError) {
        guard let data = try? JSONEncoder().encode(credentials) else { throw .corruptedItem }

        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Xcode Cloud Companion — App Store Connect API key"
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
