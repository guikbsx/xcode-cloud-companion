import Foundation
@testable import XcodeCloudCompanion

/// Cumulus Pro without StoreKit: the transactions, the offers and the answers a test decides.
actor StubProSource: ProSource {
    private var current: [ProReading]
    private var listed: [ProOffer]
    private var purchaseOutcome: ProPurchaseOutcome
    /// What the transactions become once a purchase went through.
    private var afterPurchase: [ProReading]?
    private var restoreAnswers: Bool
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var reads = 0
    private(set) var purchases: [ProProduct] = []

    init(
        _ readings: [ProReading] = [], offers: [ProOffer] = [], purchase: ProPurchaseOutcome = .unavailable,
        afterPurchase: [ProReading]? = nil, restoreAnswers: Bool = true
    ) {
        current = readings
        listed = offers
        purchaseOutcome = purchase
        self.afterPurchase = afterPurchase
        self.restoreAnswers = restoreAnswers
        (stream, continuation) = AsyncStream.makeStream()
    }

    func set(_ readings: [ProReading]) {
        current = readings
        continuation.yield()
    }

    func setOffers(_ offers: [ProOffer]) {
        listed = offers
    }

    func readings() async -> [ProReading] {
        reads += 1
        return current
    }

    nonisolated func changes() -> AsyncStream<Void> {
        stream
    }

    func offers() async -> [ProOffer] {
        listed
    }

    func purchase(_ product: ProProduct) async -> ProPurchaseOutcome {
        purchases.append(product)
        if purchaseOutcome == .purchased, let afterPurchase {
            current = afterPurchase
        }
        return purchaseOutcome
    }

    func restore() async -> Bool {
        restoreAnswers
    }
}
