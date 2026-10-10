import Foundation

nonisolated enum AppStoreConnectError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case unauthorized(status: Int)
    /// 403: the key is valid but may not do this (role, agreements). `code` tells which, when Apple gives one.
    case forbidden(code: String?, detail: String?)
    /// 409 and 422: Apple understood the request and refused it; `pointer` names the field at fault.
    case rejected(status: Int, code: String?, title: String?, detail: String?, pointer: String?)
    case rateLimited
    case server(status: Int, detail: String?)
    case network(URLError.Code)
    case decoding(String)
    case invalidResponse
}
