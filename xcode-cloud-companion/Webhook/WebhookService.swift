import Foundation
import Observation

/// Sends the alerts an account chose to its webhook. It decides whether a message may go (the event is chosen, Cumulus
/// Pro is open, the account is followed, an address is saved), never waits for the answer in the sync or in a banner,
/// and tries once more, thirty seconds later, a message that failed for want of a network or a server.
@Observable
final class WebhookService {
    struct Delivery: Equatable {
        var date: Date
        var result: WebhookResult
    }

    static let retryDelay: Duration = .seconds(30)

    /// The last send of each account, by account id: kept for the session, the address is not part of it.
    private(set) var deliveries: [String: Delivery] = [:]

    @ObservationIgnored private let accounts: AccountsModel
    @ObservationIgnored private let sender: any WebhookSending
    /// Cumulus Pro; nil leaves the function open.
    @ObservationIgnored private let pro: ProStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var sending: [UUID: Task<Void, Never>] = [:]

    init(
        accounts: AccountsModel, sender: any WebhookSending, pro: ProStore? = nil, retryDelay: Duration = WebhookService.retryDelay,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }, now: @escaping () -> Date = { Date() }
    ) {
        self.accounts = accounts
        self.sender = sender
        self.pro = pro
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.now = now
    }

    /// Whether Cumulus Pro lets webhooks go.
    var isOpen: Bool { pro?.allows(.webhookAlerts) ?? true }

    func delivery(for accountID: String) -> Delivery? {
        deliveries[accountID]
    }

    /// What the account sends, or nil when nothing may go: no Pro, an account that is paused or gone, or no address.
    func choices(for accountID: String) async -> WebhookChoices? {
        guard let model = await sendableModel(accountID) else { return nil }
        return model.choices
    }

    /// Sends each message whose event the account chose, each from a task of its own: the caller does not wait.
    func send(_ messages: [WebhookMessage], accountID: String) {
        guard !messages.isEmpty else { return }
        let id = UUID()
        sending[id] = Task {
            if let model = await sendableModel(accountID) {
                for message in messages where model.choices.includes(message.event) {
                    await deliver(message, accountID: accountID)
                }
            }
            sending[id] = nil
        }
    }

    /// The button of Settings: one attempt, whatever the account chose, and the result is the last send.
    func sendTest(accountID: String) async {
        guard let model = await sendableModel(accountID), let address = await model.address() else { return }
        let name = accounts.hasSeveral ? accounts.session(id: accountID)?.name : nil
        let result = await sender.send(WebhookMessage.test(account: name).json(for: address.kind), to: address.url)
        deliveries[accountID] = Delivery(date: now(), result: result)
    }

    /// Ends when every message handed to `send` has been answered or given up.
    func settle() async {
        while let task = sending.values.first {
            await task.value
        }
    }

    // MARK: - Private

    private func sendableModel(_ accountID: String) async -> WebhookSettingsModel? {
        guard isOpen, let session = accounts.activeSessions.first(where: { $0.id == accountID }) else { return nil }
        await session.webhook.load()
        return session.webhook.hasAddress ? session.webhook : nil
    }

    private func deliver(_ message: WebhookMessage, accountID: String) async {
        guard let model = await sendableModel(accountID), let address = await model.address() else { return }
        var result = await sender.send(message.json(for: address.kind), to: address.url)
        if result.isRetryable {
            await sleep(retryDelay)
            // What was true when the message was made may not be any more: Pro lapsed, the account went, the address changed.
            guard let model = await sendableModel(accountID), let address = await model.address() else { return }
            result = await sender.send(message.json(for: address.kind), to: address.url)
        }
        deliveries[accountID] = Delivery(date: now(), result: result)
    }
}
