import Foundation

/// What an alert is about, as a webhook names it. `test` is the one the button sends and no choice covers.
nonisolated enum WebhookEvent: String, Sendable, Equatable, CaseIterable {
    case usageAlert = "usage_alert"
    case buildStuck = "build_stuck"
    case buildFailed = "build_failed"
    case buildSucceeded = "build_succeeded"
    case test
}

/// The events an account sends to its webhook, chosen in Settings and kept for that account. The first three are on
/// until the user says otherwise; a successful build is the busiest and starts off.
nonisolated struct WebhookChoices: Codable, Sendable, Equatable {
    var usage = true
    var stuck = true
    var failed = true
    var succeeded = false

    func includes(_ event: WebhookEvent) -> Bool {
        switch event {
        case .usageAlert: usage
        case .buildStuck: stuck
        case .buildFailed: failed
        case .buildSucceeded: succeeded
        case .test: false
        }
    }

    var isEmpty: Bool { !(usage || stuck || failed || succeeded) }
}

/// What a message says beyond its text, for a receiver that wants to sort it.
nonisolated struct WebhookContext: Sendable, Equatable {
    var app: String?
    var workflow: String?
    var build: Int?
    /// A figure of the plan that is not Apple's own.
    var isEstimate = false
}

/// A banner on its way to a webhook. It is the banner already composed, title, subtitle and body, not a second wording
/// of the same event. Pure: the shape each host wants is made here, and nothing else about the message.
nonisolated struct WebhookMessage: Sendable, Equatable {
    /// Discord refuses a message above 2 000 characters.
    static let discordLimit = 2000

    var event: WebhookEvent
    var title: String
    var subtitle: String?
    var body: String
    /// The `cumulus://` address of the build or of the Overview.
    var url: URL?
    /// The account's name; set only when the app follows several.
    var account: String?
    var context = WebhookContext()

    init(event: WebhookEvent, title: String, subtitle: String? = nil, body: String, url: URL? = nil, account: String? = nil, context: WebhookContext = WebhookContext()) {
        self.event = event
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.url = url
        self.account = account
        self.context = context
    }

    init(event: WebhookEvent, banner: LocalNotification, account: String?, context: WebhookContext = WebhookContext()) {
        self.init(event: event, title: banner.title, subtitle: banner.subtitle, body: banner.body, url: banner.url, account: account, context: context)
    }

    /// The message the button sends: marked as a test, and no more than that.
    static func test(account: String?) -> WebhookMessage {
        WebhookMessage(
            event: .test, title: String(localized: "Test from Cumulus"), subtitle: account,
            body: String(localized: "If you read this, Cumulus alerts reach this channel."), account: account
        )
    }

    /// Plain text: the title, the subtitle when there is one, the body, then the address on a line of its own.
    var text: String {
        ([title, subtitle, body, url?.absoluteString] as [String?]).compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func json(for kind: WebhookKind) -> Data {
        let object: [String: Any]
        switch kind {
        case .slack:
            object = ["text": text]
        case .discord:
            object = ["content": String(text.prefix(Self.discordLimit))]
        case .generic:
            var fields: [String: Any] = ["event": event.rawValue, "title": title, "body": body, "text": text, "isEstimate": context.isEstimate]
            if let url { fields["url"] = url.absoluteString }
            if let app = context.app { fields["app"] = app }
            if let workflow = context.workflow { fields["workflow"] = workflow }
            if let build = context.build { fields["build"] = build }
            if let account { fields["account"] = account }
            object = fields
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
