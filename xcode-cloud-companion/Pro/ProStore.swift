import Foundation
import Observation

/// What a product costs and offers, as the App Store says it for this buyer. Never a price written in the code.
nonisolated struct ProOffer: Equatable, Sendable, Identifiable {
    var product: ProProduct
    var displayName: String
    var displayPrice: String
    /// The free trial this buyer may still take, in days; nil when there is none or it was already used.
    var trialDays: Int?

    var id: ProProduct { product }
}

nonisolated enum ProPurchaseOutcome: Equatable, Sendable {
    case purchased
    case cancelled
    /// Waiting for an approval (Ask to Buy): Pro is not open yet.
    case pending
    /// The App Store did not give the product: no network, or the product is not on sale.
    case unavailable
    case failed(String)
}

/// Where the transactions come from: StoreKit in the app, a stand-in under tests.
nonisolated protocol ProSource: Sendable {
    func readings() async -> [ProReading]
    /// One value each time the transactions may have changed: a purchase, a renewal, an expiry, a refund.
    func changes() -> AsyncStream<Void>
    func offers() async -> [ProOffer]
    func purchase(_ product: ProProduct) async -> ProPurchaseOutcome
    func restore() async -> Bool
}

/// The one place that says whether Cumulus Pro is open. Views and models ask `allows(_:)` and nothing else.
@Observable
final class ProStore {
    private(set) var entitlement: ProEntitlement
    private(set) var offers: [ProOffer] = []
    private(set) var isLoadingOffers = false

    private let source: any ProSource
    private let isForced: Bool
    private let now: () -> Date
    private var listener: Task<Void, Never>?
    private var recheck: Task<Void, Never>?

    /// `forced` pins the state and reads nothing: Debug captures, and tests of what a lock shows.
    init(source: any ProSource = StoreKitProSource(), forced: ProEntitlement? = nil, now: @escaping () -> Date = { Date() }) {
        self.source = source
        self.now = now
        entitlement = forced ?? .free
        isForced = forced != nil
    }

    var isPro: Bool { entitlement.isActive }

    func allows(_ feature: ProFeature) -> Bool {
        entitlement.isActive
    }

    /// Reads the transactions, then follows them for as long as the app runs.
    func start() {
        guard !isForced, listener == nil else { return }
        listener = Task { [weak self, source] in
            await self?.refresh()
            for await _ in source.changes() {
                await self?.refresh()
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        recheck?.cancel()
        recheck = nil
    }

    func refresh() async {
        guard !isForced else { return }
        let resolved = ProEntitlement.resolve(await source.readings())
        if resolved != entitlement {
            entitlement = resolved
        }
        scheduleRecheck()
    }

    func loadOffers() async {
        guard !isLoadingOffers else { return }
        isLoadingOffers = true
        offers = await source.offers()
        isLoadingOffers = false
    }

    func purchase(_ product: ProProduct) async -> ProPurchaseOutcome {
        let outcome = await source.purchase(product)
        if outcome == .purchased {
            await refresh()
        }
        return outcome
    }

    /// Asks the App Store again for what this Apple Account bought. True when the App Store answered.
    func restore() async -> Bool {
        let answered = await source.restore()
        await refresh()
        return answered
    }

    /// A period that ends does not always come with a new transaction: look again just after its end.
    private func scheduleRecheck() {
        recheck?.cancel()
        recheck = nil
        guard let end = entitlement.changesAt else { return }
        let delay = max(1, end.timeIntervalSince(now()) + 1)
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}

#if DEBUG
extension ProStore {
    /// `XCC_PRO=0|1|trial|lifetime|expired` pins the state, to look at the locks and the screens without buying.
    nonisolated static func forcedEntitlement(named name: String?, now: Date) -> ProEntitlement? {
        let month: TimeInterval = 30 * 86_400
        return switch name {
        case "0": .free
        case "1": .subscribed(until: now.addingTimeInterval(12 * month), willRenew: true)
        case "trial": .trial(ends: now.addingTimeInterval(month), willRenew: true)
        case "lifetime": .lifetime(since: now)
        case "expired": .expired(on: now.addingTimeInterval(-month))
        default: nil
        }
    }
}
#endif
