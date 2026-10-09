import CryptoKit
import Foundation

nonisolated struct AppStoreConnectToken: Sendable, Equatable {
    // Apple refuses tokens that live longer than 20 minutes.
    static let maximumLifetime: Duration = .seconds(20 * 60)

    let value: String
    let expiresAt: Date

    init(credentials: AppStoreConnectCredentials, issuedAt: Date, lifetime: Duration = maximumLifetime) throws {
        let issuedAtSeconds = Int(issuedAt.timeIntervalSince1970)
        let expiresAtSeconds = issuedAtSeconds + Int(min(lifetime, Self.maximumLifetime).components.seconds)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: credentials.keyID))
        let payload = try encoder.encode(Payload(iss: credentials.issuerID, iat: issuedAtSeconds, exp: expiresAtSeconds))

        let signingInput = header.base64URLEncodedString() + "." + payload.base64URLEncodedString()
        let signature = try credentials.privateKey.signature(for: Data(signingInput.utf8))

        value = signingInput + "." + signature.rawRepresentation.base64URLEncodedString()
        expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtSeconds))
    }

    func isUsable(at date: Date, margin: Duration = .seconds(60)) -> Bool {
        date.addingTimeInterval(TimeInterval(margin.components.seconds)) < expiresAt
    }

    private struct Header: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct Payload: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud = "appstoreconnect-v1"
    }
}

nonisolated extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }
}
