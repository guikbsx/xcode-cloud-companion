import Foundation

/// Where the page comes from; tests stand in for it.
nonisolated protocol AppleStatusFetching: Sendable {
    func fetch() async throws -> Data
}

nonisolated enum AppleStatusFetchError: Error {
    case badResponse
}

/// A bare `GET` on the public page: no query, no header of ours, no cookie, no cache, and nothing of the user's.
nonisolated struct URLSessionAppleStatusFetcher: AppleStatusFetching {
    static let sizeLimit = 4_000_000

    static var request: URLRequest {
        var request = URLRequest(url: AppleStatusSchedule.address)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    @concurrent func fetch() async throws -> Data {
        let (data, response) = try await Self.makeSession().data(for: Self.request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.sizeLimit else {
            throw AppleStatusFetchError.badResponse
        }
        return data
    }
}
