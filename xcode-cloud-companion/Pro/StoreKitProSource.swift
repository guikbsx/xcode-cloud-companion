import Foundation
import StoreKit

/// Cumulus Pro as StoreKit 2 knows it. StoreKit keeps the verified transactions on the Mac: the state is known offline.
nonisolated struct StoreKitProSource: ProSource {
    func readings() async -> [ProReading] {
        var readings: [ProReading] = []
        var hasOpenSubscription = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                readings.append(.unverified)
                continue
            }
            guard let product = ProProduct(rawValue: transaction.productID) else { continue }
            if product == .yearly {
                hasOpenSubscription = true
            }
            readings.append(.verified(await Self.transaction(transaction, product: product, isEntitled: true)))
        }
        // A subscription that ended has left the current entitlements: its last transaction says when it stopped.
        if !hasOpenSubscription, let result = await Transaction.latest(for: ProProduct.yearly.rawValue) {
            if case .verified(let transaction) = result {
                readings.append(.verified(await Self.transaction(transaction, product: .yearly, isEntitled: false)))
            } else {
                readings.append(.unverified)
            }
        }
        return readings
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let transactions = Task {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    continuation.yield()
                }
            }
            // An expiry or a refused payment changes the subscription's status without a new transaction.
            let statuses = Task {
                for await _ in Product.SubscriptionInfo.Status.updates {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                transactions.cancel()
                statuses.cancel()
            }
        }
    }

    func offers() async -> [ProOffer] {
        guard let products = try? await Product.products(for: ProProduct.allCases.map(\.rawValue)) else { return [] }
        var offers: [ProOffer] = []
        for product in products {
            guard let kind = ProProduct(rawValue: product.id) else { continue }
            var trialDays: Int?
            if let subscription = product.subscription, let introductory = subscription.introductoryOffer,
               introductory.paymentMode == .freeTrial, await subscription.isEligibleForIntroOffer {
                trialDays = Self.days(in: introductory.period) * introductory.periodCount
            }
            offers.append(ProOffer(product: kind, displayName: product.displayName, displayPrice: product.displayPrice, trialDays: trialDays))
        }
        return offers.sorted { $0.product == .yearly && $1.product != .yearly }
    }

    func purchase(_ product: ProProduct) async -> ProPurchaseOutcome {
        guard let item = try? await Product.products(for: [product.rawValue]).first else { return .unavailable }
        do {
            switch try await item.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { return .failed(String(localized: "The App Store could not verify this purchase.")) }
                await transaction.finish()
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(String(localized: "The App Store gave an answer Cumulus does not know."))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async -> Bool {
        (try? await AppStore.sync()) != nil
    }

    private static func transaction(_ transaction: Transaction, product: ProProduct, isEntitled: Bool) async -> ProTransaction {
        var standing: ProTransaction.Standing = isEntitled ? .current : .ended
        var willRenew = true
        if product == .yearly, let status = await status(of: transaction) {
            switch status.state {
            case .inGracePeriod: standing = .gracePeriod
            case .inBillingRetryPeriod: standing = .billingRetry
            default: break
            }
            if case .verified(let renewal) = status.renewalInfo {
                willRenew = renewal.willAutoRenew
            }
        }
        return ProTransaction(
            product: product,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isTrial: transaction.offer?.paymentMode == .freeTrial,
            standing: standing,
            willRenew: willRenew
        )
    }

    private static func status(of transaction: Transaction) async -> Product.SubscriptionInfo.Status? {
        guard let group = transaction.subscriptionGroupID,
              let statuses = try? await Product.SubscriptionInfo.status(for: group)
        else { return nil }
        return statuses.first { status in
            guard case .verified(let latest) = status.transaction else { return false }
            return latest.productID == transaction.productID
        }
    }

    private static func days(in period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day: period.value
        case .week: period.value * 7
        case .month: period.value * 30
        case .year: period.value * 365
        @unknown default: period.value
        }
    }
}
