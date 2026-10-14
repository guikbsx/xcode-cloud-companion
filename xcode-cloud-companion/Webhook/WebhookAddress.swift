import Foundation

/// Why a typed address is not kept.
nonisolated enum WebhookAddressError: Error, Equatable, Sendable {
    case notHTTPS
    case invalid

    var message: String {
        switch self {
        case .notHTTPS: String(localized: "Only an address that starts with https:// is accepted.")
        case .invalid: String(localized: "This is not a web address.")
        }
    }
}

/// How an address wants its message: Slack and Discord each have their own shape, any other address gets Cumulus' own.
nonisolated enum WebhookKind: Sendable, Equatable {
    case slack
    case discord
    case generic
}

/// The address of a webhook: a secret, since whoever has it can post in the channel. It lives in the keychain, and its
/// text is never printed: only its host is ever shown.
nonisolated struct WebhookAddress: Sendable, Equatable {
    let url: URL
    let host: String

    init(_ text: String) throws(WebhookAddressError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed), let scheme = components.scheme
        else { throw .invalid }
        guard scheme.lowercased() == "https" else { throw .notHTTPS }
        guard let host = components.host?.lowercased(), !host.isEmpty, let url = components.url else { throw .invalid }
        self.url = url
        self.host = host
    }

    var kind: WebhookKind {
        let path = url.path(percentEncoded: false)
        if host == "hooks.slack.com" { return .slack }
        if host == "discord.com" || host == "discordapp.com" || host.hasSuffix(".discord.com"), path.hasPrefix("/api/webhooks") { return .discord }
        return .generic
    }

    /// What the interface shows of a saved address.
    var masked: String {
        "\(host)/••••••••"
    }
}

extension WebhookAddress: CustomStringConvertible, CustomDebugStringConvertible {
    nonisolated var description: String { "WebhookAddress(host: \(host))" }
    nonisolated var debugDescription: String { description }
}
