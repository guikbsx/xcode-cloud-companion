import Foundation

nonisolated enum AppStoreConnectError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case unauthorized(status: Int)
    case rateLimited
    case server(status: Int, detail: String?)
    case network(URLError.Code)
    case decoding(String)
    case invalidResponse
}
