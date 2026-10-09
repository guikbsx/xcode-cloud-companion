import CryptoKit
import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AppStoreConnectTokenTests {
    private let issuedAt = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func signatureVerifiesWithThePublicKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        let token = try AppStoreConnectToken(credentials: .sample(privateKey: privateKey), issuedAt: issuedAt)

        let parts = token.value.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64URLEncoded: parts[2])))
        #expect(privateKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test func headerAndPayloadFollowApplesFormat() throws {
        let token = try AppStoreConnectToken(credentials: .sample(), issuedAt: issuedAt)
        let parts = token.value.split(separator: ".").map(String.init)

        let header = try JSONSerialization.jsonObject(with: try #require(Data(base64URLEncoded: parts[0]))) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "KEY123")
        #expect(header?["typ"] as? String == "JWT")

        let payload = try JSONSerialization.jsonObject(with: try #require(Data(base64URLEncoded: parts[1]))) as? [String: Any]
        #expect(payload?["iss"] as? String == "issuer-123")
        #expect(payload?["aud"] as? String == "appstoreconnect-v1")
        #expect(payload?["iat"] as? Int == 1_791_000_000)
        #expect(payload?["exp"] as? Int == 1_791_000_000 + 20 * 60)
    }

    @Test func lifetimeNeverExceedsTwentyMinutes() throws {
        let token = try AppStoreConnectToken(credentials: .sample(), issuedAt: issuedAt, lifetime: .seconds(3600))

        #expect(token.expiresAt == issuedAt.addingTimeInterval(20 * 60))
    }

    @Test func tokenStopsBeingUsableOneMinuteBeforeExpiry() throws {
        let token = try AppStoreConnectToken(credentials: .sample(), issuedAt: issuedAt)

        #expect(token.isUsable(at: issuedAt.addingTimeInterval(18 * 60)))
        #expect(!token.isUsable(at: issuedAt.addingTimeInterval(19 * 60)))
    }

    @Test func credentialsLoadFromAPKCS8PEM() throws {
        let privateKey = P256.Signing.PrivateKey()

        let credentials = try AppStoreConnectCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: privateKey.pemRepresentation)

        #expect(credentials.privateKey.publicKey.rawRepresentation == privateKey.publicKey.rawRepresentation)
    }

    @Test func invalidPEMIsRejected() {
        #expect(throws: AppStoreConnectError.invalidPrivateKey) {
            try AppStoreConnectCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "not a key")
        }
    }

    @Test func credentialsNeverPrintTheirPrivateKey() {
        let privateKey = P256.Signing.PrivateKey()
        let credentials = AppStoreConnectCredentials.sample(privateKey: privateKey)

        for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials)"] {
            #expect(!text.contains("PRIVATE KEY"))
            #expect(!text.contains(privateKey.rawRepresentation.base64EncodedString()))
        }
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
