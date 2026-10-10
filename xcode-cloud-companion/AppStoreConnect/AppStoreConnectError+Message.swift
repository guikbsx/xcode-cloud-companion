import Foundation
import Security

nonisolated extension AppStoreConnectError {
    var message: String {
        switch self {
        case .invalidPrivateKey:
            String(localized: "The private key can’t be read. Import the .p8 file downloaded from App Store Connect.")
        case .unauthorized:
            String(localized: "App Store Connect refused the key. Check the Issuer ID, the Key ID, and that the key is still active.")
        case .forbidden(let code, let detail):
            if let code, code.hasSuffix("REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED") || code.hasSuffix("PLA_NOT_VALID") {
                String(localized: "An agreement of your team is missing or has expired. The Account Holder must accept it in App Store Connect.")
            } else {
                String(localized: "This API key isn’t allowed to do that. Check its role, and that it is a team key.") + (detail.map { " \($0)" } ?? "")
            }
        case .rejected(_, _, let title, let detail, _):
            switch (title, detail) {
            case let (title?, detail?): String(localized: "\(title): \(detail)", comment: "Apple's refusal: its title, then its detail")
            case let (title?, nil): title
            case let (nil, detail?): detail
            case (nil, nil): String(localized: "App Store Connect refused the request.")
            }
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
        case .keychain(errSecInvalidOwnerEdit):
            // The legacy keychain lets only the build that saved an item delete it, by code signature.
            return String(localized: "This key was saved by another build of the app, and macOS only lets that build delete it. In Keychain Access, delete “\(KeychainCredentialsStore.defaultService)”, then try again.")
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            let code = String(status)
            return String(localized: "The keychain refused the operation: \(reason) (\(code))", comment: "The last part is the keychain's error code, kept for support.")
        case .corruptedItem:
            return String(localized: "The key stored in the keychain is unreadable. Remove it and import it again.")
        }
    }
}
