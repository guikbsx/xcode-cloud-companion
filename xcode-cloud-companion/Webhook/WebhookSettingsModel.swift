import Foundation
import Observation

/// One account's webhook: its address, kept in the keychain, and the events it is sent. Only the host of the address
/// is ever held here for the interface; the address itself is read from the keychain when a message goes out.
@Observable
final class WebhookSettingsModel {
    let accountID: String
    private(set) var host: String?
    private(set) var hasLoaded = false
    /// Why the last address typed was not kept.
    private(set) var addressError: WebhookAddressError?
    /// Why the keychain did not do what it was asked.
    private(set) var errorMessage: String?
    var choices: WebhookChoices {
        didSet {
            guard choices != oldValue, let data = try? JSONEncoder().encode(choices) else { return }
            defaults.set(data, forKey: AccountDefaults.key(AccountDefaults.webhookEvents, accountID: accountID))
        }
    }

    @ObservationIgnored private let store: any WebhookAddressStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(accountID: String, store: any WebhookAddressStore = InMemoryWebhookAddressStore(), defaults: UserDefaults = .standard) {
        self.accountID = accountID
        self.store = store
        self.defaults = defaults
        choices = defaults.data(forKey: AccountDefaults.key(AccountDefaults.webhookEvents, accountID: accountID))
            .flatMap { try? JSONDecoder().decode(WebhookChoices.self, from: $0) } ?? WebhookChoices()
    }

    var hasAddress: Bool { host != nil }

    /// What the interface shows of the saved address.
    var maskedAddress: String? { host.map { "\($0)/••••••••" } }

    /// Reads the keychain once, however many callers wait for it.
    func load() async {
        if let loading {
            await loading.value
            return
        }
        guard !hasLoaded else { return }
        let task = Task { await read() }
        loading = task
        await task.value
        loading = nil
    }

    private func read() async {
        do {
            host = try await store.load().flatMap { try? WebhookAddress($0).host }
        } catch {
            errorMessage = error.message
        }
        hasLoaded = true
    }

    /// The saved address, read from the keychain for one message.
    func address() async -> WebhookAddress? {
        guard let text = try? await store.load() else { return nil }
        return try? WebhookAddress(text)
    }

    /// Keeps what was typed when it is an https address; an empty field removes the address. True when it is kept or removed.
    @discardableResult
    func commit(_ text: String) async -> Bool {
        addressError = nil
        errorMessage = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await remove()
        }
        let address: WebhookAddress
        do {
            address = try WebhookAddress(text)
        } catch {
            addressError = error
            return false
        }
        do {
            try await store.save(address.url.absoluteString)
        } catch {
            errorMessage = error.message
            return false
        }
        host = address.host
        hasLoaded = true
        return true
    }

    @discardableResult
    func remove() async -> Bool {
        addressError = nil
        do {
            try await store.delete()
        } catch {
            errorMessage = error.message
            return false
        }
        host = nil
        errorMessage = nil
        return true
    }

    func clearAddressError() {
        addressError = nil
    }
}
