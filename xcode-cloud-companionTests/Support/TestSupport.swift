import CryptoKit
import Foundation
import Synchronization
@testable import XcodeCloudCompanion

enum Fixture {
    struct Missing: Error {
        let name: String
    }

    static func data(_ name: String) throws -> Data {
        try load(name, withExtension: "json")
    }

    static func csv(_ name: String) throws -> Data {
        try load(name, withExtension: "csv")
    }

    private static func load(_ name: String, withExtension fileExtension: String) throws -> Data {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: fileExtension) else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }
}

private final class BundleToken {}

extension AppStoreConnectCredentials {
    static func sample(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> AppStoreConnectCredentials {
        AppStoreConnectCredentials(issuerID: "issuer-123", keyID: "KEY123", privateKey: privateKey)
    }
}

final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date) {
        self.date = Mutex(date)
    }

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0.addTimeInterval(seconds) }
    }
}

actor MockTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError?
        var headers: [String: String] = [:]
    }

    private(set) var requests: [URLRequest] = []
    private let reply: @Sendable (URLRequest) -> Reply

    init(reply: @escaping @Sendable (URLRequest) -> Reply) {
        self.reply = reply
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = reply(request)
        if let error = reply.error {
            throw error
        }
        let response = HTTPURLResponse(url: request.url ?? URL(filePath: "/"), statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)
        return (reply.body, response ?? URLResponse())
    }
}

extension URLRequest {
    func queryValue(_ name: String) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
