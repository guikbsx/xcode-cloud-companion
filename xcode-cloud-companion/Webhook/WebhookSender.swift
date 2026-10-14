import Foundation

/// What a webhook answered. Nothing else about the exchange is kept: the address and the reply never leave the sender.
nonisolated enum WebhookResult: Sendable, Equatable {
    case delivered
    /// The HTTP status of a reply that is not a success.
    case refused(Int)
    /// No reply: the network failed or the wait ran out.
    case unreachable

    /// A server error or a network failure may pass; a refusal by the receiver will not.
    var isRetryable: Bool {
        switch self {
        case .delivered: false
        case .refused(let status): status >= 500
        case .unreachable: true
        }
    }
}

/// Posts a JSON body to an address; tests stand in for it.
nonisolated protocol WebhookSending: Sendable {
    func send(_ body: Data, to url: URL) async -> WebhookResult
}

/// Posts through an ephemeral session: no cookie, no cache, nothing kept. A redirect is not followed, since the message
/// goes to the address that was typed and to no other.
nonisolated struct URLSessionWebhookSender: WebhookSending {
    static let timeout: TimeInterval = 10

    @concurrent func send(_ body: Data, to url: URL) async -> WebhookResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout * 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.data(for: request, delegate: RedirectRefusal())
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
            return (200..<300).contains(status) ? .delivered : .refused(status)
        } catch {
            return .unreachable
        }
    }
}

private nonisolated final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// What the app has when nothing may be sent: under tests, and for an account that was handed no sender.
nonisolated struct UnreachableWebhookSender: WebhookSending {
    func send(_ body: Data, to url: URL) async -> WebhookResult {
        .unreachable
    }
}
