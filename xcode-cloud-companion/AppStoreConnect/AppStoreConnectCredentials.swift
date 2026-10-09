import CryptoKit
import Foundation

nonisolated struct AppStoreConnectCredentials: Sendable {
    let issuerID: String
    let keyID: String
    let privateKey: P256.Signing.PrivateKey

    init(issuerID: String, keyID: String, privateKey: P256.Signing.PrivateKey) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.privateKey = privateKey
    }

    init(issuerID: String, keyID: String, privateKeyPEM: String) throws(AppStoreConnectError) {
        do {
            let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
            self.init(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
        } catch {
            throw .invalidPrivateKey
        }
    }
}

extension AppStoreConnectCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    nonisolated var description: String { "AppStoreConnectCredentials(keyID: \(keyID), privateKey: <redacted>)" }
    nonisolated var debugDescription: String { description }
}
