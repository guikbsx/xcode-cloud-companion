import Foundation

/// The two products of Cumulus Pro, as created in App Store Connect. An identifier never changes once created.
nonisolated enum ProProduct: String, CaseIterable, Sendable {
    case yearly = "com.guik.cumulus.pro.yearly"
    case lifetime = "com.guik.cumulus.pro.lifetime"
}

/// One purchase of Cumulus Pro as StoreKit reports it, reduced to what the entitlement is worked out from.
nonisolated struct ProTransaction: Equatable, Sendable {
    /// Where a subscription stands. Grace period and billing retry are Apple trying the payment again: Pro stays open.
    enum Standing: Equatable, Sendable {
        case current, gracePeriod, billingRetry, ended
    }

    var product: ProProduct
    var purchaseDate: Date
    /// When the paid or trial period ends; nil for the lifetime purchase.
    var expirationDate: Date?
    /// Refunded, or taken back by Apple.
    var revocationDate: Date?
    /// The free month before the first payment.
    var isTrial = false
    var standing: Standing = .current
    /// False once the subscriber turned renewal off: the period runs to its end, then stops.
    var willRenew = true
}

/// What StoreKit handed over: a transaction it vouches for, or one whose signature it could not verify.
nonisolated enum ProReading: Equatable, Sendable {
    case verified(ProTransaction)
    case unverified
}

/// Whether Cumulus Pro is open, and why. The only source is StoreKit's transactions: nothing here is ever stored.
nonisolated enum ProEntitlement: Equatable, Sendable {
    case free
    case trial(ends: Date, willRenew: Bool)
    case subscribed(until: Date, willRenew: Bool)
    case lifetime(since: Date)
    /// A subscription that ended, or was refunded: nothing is erased, Pro is paused.
    case expired(on: Date)

    var isActive: Bool {
        switch self {
        case .trial, .subscribed, .lifetime: true
        case .free, .expired: false
        }
    }

    /// When this state stops being true by itself, if it does: the moment to look at the transactions again.
    var changesAt: Date? {
        switch self {
        case .trial(let ends, _): ends
        case .subscribed(let until, _): until
        case .free, .lifetime, .expired: nil
        }
    }

    /// A transaction StoreKit could not verify never opens Pro. The lifetime purchase wins over any subscription.
    static func resolve(_ readings: [ProReading]) -> ProEntitlement {
        let transactions = readings.compactMap { reading -> ProTransaction? in
            guard case .verified(let transaction) = reading else { return nil }
            return transaction
        }
        if let lifetime = transactions.first(where: { $0.product == .lifetime && $0.revocationDate == nil }) {
            return .lifetime(since: lifetime.purchaseDate)
        }
        let subscriptions = transactions
            .filter { $0.product == .yearly }
            .sorted { $0.purchaseDate > $1.purchaseDate }
        if let open = subscriptions.first(where: { $0.revocationDate == nil && $0.standing != .ended }), let end = open.expirationDate {
            return open.isTrial ? .trial(ends: end, willRenew: open.willRenew) : .subscribed(until: end, willRenew: open.willRenew)
        }
        if let last = subscriptions.first, let end = last.revocationDate ?? last.expirationDate {
            return .expired(on: end)
        }
        return .free
    }
}

/// Every function that asks for Cumulus Pro. A lock is a case here, so that the split between free and Pro reads in
/// one place (decided on 13/10/2026, XCO-132).
nonisolated enum ProFeature: String, CaseIterable, Sendable {
    case multipleAccounts
    /// The alerts at 75 % of the plan and on the pace. The alert at 90 % is free.
    case earlyUsageAlerts
    case stuckBuildAlert
    /// The banner that says a workflow got slower. The card in the trends is `workflowTrends`.
    case slowdownAlert
    /// The alerts of the plan, of a stuck build and of a build's end, sent to a Slack, Discord or generic webhook.
    case webhookAlerts
    /// The TestFlight card of an app, the commit-to-testers timeline of a build, and the banners for a build that becomes
    /// available to external testers or is about to expire. The card of a build's TestFlight builds stays free.
    case testFlightTracking
    case regressions
    /// The summary line and the suggested groups, written on this Mac by Apple Intelligence.
    case failureInsight
    /// The lines of the log around the error, in the card of a failed build.
    case logExcerpt
    case testHealth
    case workflowTrends
    case workflowCostBreakdown
    case upcomingBuilds
    case appOverview
    case pauseWorkflow
    case editWorkflow
    case olderBuilds
    case openInXcode
    /// Every `cumulus` command but `status`.
    case commandLine
    case mcpServer
}
