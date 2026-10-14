import Foundation

/// The words Settings uses for a webhook's last send.
nonisolated enum WebhookText {
    /// “Last send: refused, 404 · 14:36”. Never the address, nor what the receiver answered beyond its status.
    static func lastSend(_ result: WebhookResult, at date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let outcome = switch result {
        case .delivered: String(localized: "Last send: sent")
        case .refused(let status): String(localized: "Last send: refused, \(String(status))")
        case .unreachable: String(localized: "Last send: could not be reached")
        }
        return outcome + " · " + date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static let formatExample = """
    {
      "event": "build_failed",
      "title": "Brioche #412 failed",
      "body": "…",
      "app": "Brioche",
      "workflow": "Pull Requests",
      "build": 412,
      "url": "cumulus://build/…",
      "isEstimate": false,
      "text": "…"
    }
    """
}
