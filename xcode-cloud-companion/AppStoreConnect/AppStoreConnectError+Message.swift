import Foundation
import Security

nonisolated extension AppStoreConnectError {
    var message: String {
        switch self {
        case .invalidPrivateKey:
            String(localized: "The private key can’t be read. Import the .p8 file downloaded from App Store Connect.")
        case .unauthorized:
            String(localized: "App Store Connect refused the key. Check the Issuer ID, the Key ID, and that the key is still active.")
        case .rateLimited:
            String(localized: "App Store Connect is limiting requests. Try again in a few minutes.")
        case .server(let status, let detail):
            String(localized: "App Store Connect returned an error (\(status))") + (detail.map { ": \($0)" } ?? ".")
        case .network(let code) where code == .notConnectedToInternet:
            String(localized: "No internet connection.")
        case .network:
            String(localized: "App Store Connect can’t be reached.")
        case .decoding, .invalidResponse:
            String(localized: "App Store Connect sent an unexpected response.")
        }
    }
}

nonisolated extension CredentialsStoreError {
    var message: String {
        switch self {
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            return String(localized: "The keychain refused the operation: \(reason)")
        case .corruptedItem:
            return String(localized: "The key stored in the keychain is unreadable. Remove it and import it again.")
        }
    }
}
