import Foundation
import Synchronization
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

    private final class FakeFetcher: ArtifactFetching {
        private let results: Mutex<[Result<ArtifactFetchResult, URLError>]>
        let addresses = Mutex<[URL]>([])

        init(_ results: [Result<ArtifactFetchResult, URLError>]) {
            self.results = Mutex(results)
        }

        func fetch(_ address: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> ArtifactFetchResult {
            addresses.withLock { $0.append(address) }
            progress(0.5)
            return try results.withLock { $0.isEmpty ? .success(.status(500)) : $0.removeFirst() }.get()
        }
    }

    private func temporaryFile(_ text: String = "payload") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "artifact-\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "saved-\(UUID().uuidString).zip")
    }

    private func saver(
        body: Data? = nil, status: Int = 200, fetcher: FakeFetcher, destination: URL?
    ) -> (ArtifactSaver, MockTransport) {
        let transport = MockTransport { _ in
            MockTransport.Reply(status: status, body: body ?? ((try? Fixture.data("ciArtifact-sample")) ?? Data()), headers: [:])
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return (ArtifactSaver(client: { client }, fetcher: fetcher, chooseDestination: { _ in destination }), transport)
    }

    @Test func aFreshAddressIsAskedForThenTheFileIsSavedWhereTheUserChose() async throws {
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let fetcher = FakeFetcher([.success(.file(try temporaryFile("hello")))])
        let (saver, transport) = saver(fetcher: fetcher, destination: target)

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .saved(target))
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello")
        #expect(fetcher.addresses.withLock { $0.map(\.host) } == ["example.icloud-content.com"])
        #expect(await transport.requests.count == 1)
    }

    @Test func aRefusedLinkIsReplacedByAFreshOneOnceAndThenSucceeds() async throws {
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target) }
        let fetcher = FakeFetcher([.success(.status(403)), .success(.file(try temporaryFile()))])
        let (saver, transport) = saver(fetcher: fetcher, destination: target)

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .saved(target))
        #expect(await transport.requests.count == 2)
        #expect(fetcher.addresses.withLock { $0.count } == 2)
    }

    @Test func aLinkRefusedTwiceReportsTheCodeAndWritesNothing() async throws {
        let target = destination()
        let fetcher = FakeFetcher([.success(.status(403)), .success(.status(403))])
        let (saver, _) = saver(fetcher: fetcher, destination: target)

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .failed("The link expired or is invalid (HTTP 403)."))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(fetcher.addresses.withLock { $0.count } == 2)
    }

    @Test func anUntrustedHostDownloadsNothing() async throws {
        let body = Data(#"{"data":{"type":"ciArtifacts","id":"art-1","attributes":{"fileType":"X","downloadUrl":"https://evil.example.com/a"}}}"#.utf8)
        let fetcher = FakeFetcher([])
        let (saver, _) = saver(body: body, fetcher: fetcher, destination: destination())

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .failed(ArtifactSaver.message(for: .unexpectedHost)))
        #expect(fetcher.addresses.withLock { $0.isEmpty })
    }

    @Test func closingThePanelStartsNothing() async {
        let fetcher = FakeFetcher([])
        let (saver, transport) = saver(fetcher: fetcher, destination: nil)

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .idle)
        #expect(await transport.requests.isEmpty)
    }

    @Test func aCancelledDownloadGoesBackToIdleAndLeavesNoFile() async {
        let target = destination()
        let fetcher = FakeFetcher([.failure(URLError(.cancelled))])
        let (saver, _) = saver(fetcher: fetcher, destination: target)

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .idle)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aNetworkFailureIsReported() async {
        let fetcher = FakeFetcher([.failure(URLError(.networkConnectionLost))])
        let (saver, _) = saver(fetcher: fetcher, destination: destination())

        await saver.save(artifact())

        #expect(saver.state(of: "art-1") == .failed("The download could not be completed."))
    }

    @Test func theDownloadRequestCarriesNoCredentialAndNoCookie() async throws {
        final class Probe: URLProtocol {
            static let seen = Mutex<[URLRequest]>([])
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.seen.withLock { $0.append(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("nope".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Probe.self]

        let result = try await URLSessionArtifactFetcher(configuration: configuration).fetch(try #require(URL(string: "https://example.icloud-content.com/a?sig=1")), progress: { _ in })

        #expect(result == .status(404))
        let request = try #require(Probe.seen.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func theDownloadAddressIsNeverWrittenToDisk() throws {
        let leaked = CIArtifact(id: "a", buildActionID: "b", fileType: "X", fileName: "f", fileSize: 1, downloadURL: URL(string: "https://apple.com/secret?sig=1"))

        let data = try JSONEncoder().encode(leaked)
        let decoded = try JSONDecoder().decode(CIArtifact.self, from: data)

        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(decoded.downloadURL == nil && decoded.fileName == "f")
    }
}
