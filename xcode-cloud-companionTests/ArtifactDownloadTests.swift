import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ArtifactDownloadTests {
    @Test(arguments: [
        "https://example.icloud-content.com/abc?signature=xyz", "https://icloud-content.com/a", "https://x.y.apple.com/file.zip", "https://apple.com/a",
    ])
    func trustedAddressesAreAccepted(address: String) throws {
        #expect(try ArtifactAddress.validated(URL(string: address)).absoluteString == address)
    }

    @Test(arguments: [
        "http://example.icloud-content.com/a", "https://evilapple.com/a", "https://apple.com.evil.com/a", "https://evil.com/apple.com",
        "https://apple.com@evil.com/a", "https://user:pw@apple.com/a", "https://apple.com:8443/a", "ftp://apple.com/a", "https://icloud-content.com.attacker.net/",
    ])
    func everythingElseIsRefused(address: String) {
        #expect(throws: ArtifactAddress.Refusal.self) { try ArtifactAddress.validated(URL(string: address)) }
    }

    @Test func aMissingAddressIsRefused() {
        #expect(throws: ArtifactAddress.Refusal.missing) { try ArtifactAddress.validated(nil) }
    }

    private func artifact() -> CIArtifact {
        CIArtifact(id: "art-1", buildActionID: "action-1", fileType: "LOG_BUNDLE", fileName: "Logs.zip", fileSize: 2048, downloadURL: nil)
    }

    private final class Opened {
        var urls: [URL] = []
    }

    private func opener(reply: @escaping @Sendable (URLRequest) -> MockTransport.Reply, opened: Opened) -> (ArtifactOpener, MockTransport) {
        let transport = MockTransport(reply: reply)
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return (ArtifactOpener(client: { client }, open: { opened.urls.append($0) }), transport)
    }

    @Test func aFreshAddressIsAskedForThenOpenedAndForgotten() async throws {
        let opened = Opened()
        let (opener, transport) = opener(reply: { _ in
            MockTransport.Reply(status: 200, body: (try? Fixture.data("ciArtifact-sample")) ?? Data(), headers: [:])
        }, opened: opened)

        await opener.download(artifact())

        #expect(opened.urls.map(\.host) == ["example.icloud-content.com"])
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.url?.path() == "/v1/ciArtifacts/art-1")
        #expect(opener.state(of: "art-1") == .idle)
    }

    @Test func anUntrustedHostOpensNothingAndSaysSo() async throws {
        let opened = Opened()
        let body = Data(#"{"data":{"type":"ciArtifacts","id":"art-1","attributes":{"fileType":"X","downloadUrl":"https://evil.example.com/a"}}}"#.utf8)
        let (opener, _) = opener(reply: { _ in MockTransport.Reply(status: 200, body: body, headers: [:]) }, opened: opened)

        await opener.download(artifact())

        #expect(opened.urls.isEmpty)
        #expect(opener.state(of: "art-1") == .failed(ArtifactOpener.message(for: .unexpectedHost)))
    }

    @Test func anExpiredOrRefusedRequestReportsApplesErrorAndOpensNothing() async throws {
        let opened = Opened()
        let (opener, _) = opener(reply: { _ in MockTransport.Reply(status: 404, body: Data(), headers: [:]) }, opened: opened)

        await opener.download(artifact())

        guard case .failed = opener.state(of: "art-1") else {
            Issue.record("expected a failure")
            return
        }
        #expect(opened.urls.isEmpty)
    }

    @Test func theDownloadAddressIsNeverWrittenToDisk() throws {
        let leaked = CIArtifact(id: "a", buildActionID: "b", fileType: "X", fileName: "f", fileSize: 1, downloadURL: URL(string: "https://apple.com/secret?sig=1"))

        let data = try JSONEncoder().encode(leaked)
        let decoded = try JSONDecoder().decode(CIArtifact.self, from: data)

        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(decoded.downloadURL == nil && decoded.fileName == "f")
    }
}
