import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import XcodeCloudCompanion

struct ProEntitlementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nextMonth: Date { now.addingTimeInterval(30 * 86_400) }
    private var lastMonth: Date { now.addingTimeInterval(-30 * 86_400) }

    private func yearly(
        ends: Date, trial: Bool = false, standing: ProTransaction.Standing = .current, revoked: Date? = nil, willRenew: Bool = true, purchased: Date? = nil
    ) -> ProReading {
        .verified(ProTransaction(
            product: .yearly, purchaseDate: purchased ?? lastMonth, expirationDate: ends, revocationDate: revoked, isTrial: trial, standing: standing, willRenew: willRenew
        ))
    }

    private func lifetime(revoked: Date? = nil) -> ProReading {
        .verified(ProTransaction(product: .lifetime, purchaseDate: lastMonth, revocationDate: revoked))
    }

    @Test func withoutAPurchaseCumulusIsFree() {
        #expect(ProEntitlement.resolve([]) == .free)
        #expect(!ProEntitlement.free.isActive)
    }

    @Test func theFreeMonthIsATrialThatSaysWhenItEnds() {
        let entitlement = ProEntitlement.resolve([yearly(ends: nextMonth, trial: true)])

        #expect(entitlement == .trial(ends: nextMonth, willRenew: true))
        #expect(entitlement.isActive && entitlement.changesAt == nextMonth)
    }

    @Test func aPaidYearIsASubscriptionAndSaysWhetherItRenews() {
        #expect(ProEntitlement.resolve([yearly(ends: nextMonth)]) == .subscribed(until: nextMonth, willRenew: true))
        #expect(ProEntitlement.resolve([yearly(ends: nextMonth, willRenew: false)]) == .subscribed(until: nextMonth, willRenew: false))
    }

    @Test func anEndedSubscriptionIsExpiredNotFree() {
        let entitlement = ProEntitlement.resolve([yearly(ends: lastMonth, standing: .ended)])

        #expect(entitlement == .expired(on: lastMonth))
        #expect(!entitlement.isActive && entitlement.changesAt == nil)
    }

    @Test func aRefundedSubscriptionClosesProOnTheDayOfTheRefund() {
        #expect(ProEntitlement.resolve([yearly(ends: nextMonth, revoked: now)]) == .expired(on: now))
    }

    @Test func graceAndBillingRetryKeepProOpen() {
        #expect(ProEntitlement.resolve([yearly(ends: lastMonth, standing: .gracePeriod)]).isActive)
        #expect(ProEntitlement.resolve([yearly(ends: lastMonth, standing: .billingRetry)]).isActive)
    }

    @Test func theLifetimePurchaseWinsOverAnySubscription() {
        #expect(ProEntitlement.resolve([yearly(ends: nextMonth), lifetime()]) == .lifetime(since: lastMonth))
        #expect(ProEntitlement.resolve([lifetime(), yearly(ends: lastMonth, standing: .ended)]) == .lifetime(since: lastMonth))
        #expect(ProEntitlement.resolve([lifetime()]).changesAt == nil)
    }

    @Test func aRefundedLifetimePurchaseOpensNothing() {
        #expect(ProEntitlement.resolve([lifetime(revoked: now)]) == .free)
        #expect(ProEntitlement.resolve([lifetime(revoked: now), yearly(ends: nextMonth)]) == .subscribed(until: nextMonth, willRenew: true))
    }

    @Test func aTransactionStoreKitCouldNotVerifyNeverOpensPro() {
        #expect(ProEntitlement.resolve([.unverified]) == .free)
        #expect(ProEntitlement.resolve([.unverified, yearly(ends: lastMonth, standing: .ended)]) == .expired(on: lastMonth))
    }

    @Test func theNewestSubscriptionSpeaks() {
        let renewed = yearly(ends: nextMonth, purchased: now)
        let before = yearly(ends: lastMonth, standing: .ended, purchased: lastMonth.addingTimeInterval(-86_400))

        #expect(ProEntitlement.resolve([before, renewed]) == .subscribed(until: nextMonth, willRenew: true))
    }

    @Test func theProductIdentifiersAreTheOnesOfAppStoreConnect() {
        #expect(ProProduct.yearly.rawValue == "com.guik.cumulus.pro.yearly")
        #expect(ProProduct.lifetime.rawValue == "com.guik.cumulus.pro.lifetime")
    }
}

/// Transactions a test hands over, and a way to say they changed.
private actor StubProSource: ProSource {
    private var current: [ProReading]
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var reads = 0

    init(_ readings: [ProReading] = []) {
        current = readings
        (stream, continuation) = AsyncStream.makeStream()
    }

    func set(_ readings: [ProReading]) {
        current = readings
        continuation.yield()
    }

    func readings() async -> [ProReading] {
        reads += 1
        return current
    }

    nonisolated func changes() -> AsyncStream<Void> {
        stream
    }

    func offers() async -> [ProOffer] { [] }
    func purchase(_ product: ProProduct) async -> ProPurchaseOutcome { .unavailable }
    func restore() async -> Bool { true }
}

@MainActor
struct ProStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func subscription(ends: Date, standing: ProTransaction.Standing = .current) -> ProReading {
        .verified(ProTransaction(product: .yearly, purchaseDate: now.addingTimeInterval(-86_400), expirationDate: ends, standing: standing))
    }

    private func wait(for condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func everyProFeatureIsClosedWhenFreeAndOpenWithPro() async {
        let end = now.addingTimeInterval(86_400 * 300)
        let free = ProStore(source: StubProSource(), now: { self.now })
        let pro = ProStore(source: StubProSource([subscription(ends: end)]), now: { self.now })
        await free.refresh()
        await pro.refresh()

        let closedWhenFree = ProFeature.allCases.filter { free.allows($0) }
        let closedWithPro = ProFeature.allCases.filter { !pro.allows($0) }
        #expect(closedWhenFree.isEmpty && closedWithPro.isEmpty)
        #expect(!free.isPro && pro.isPro)
    }

    @Test func theStateFollowsTheTransactionsWithoutARelaunch() async {
        let source = StubProSource()
        let store = ProStore(source: source, now: { self.now })
        store.start()
        defer { store.stop() }
        #expect(store.entitlement == .free)

        let end = now.addingTimeInterval(86_400 * 300)
        await source.set([subscription(ends: end)])
        await wait { store.isPro }
        #expect(store.entitlement == .subscribed(until: end, willRenew: true))

        await source.set([subscription(ends: now.addingTimeInterval(-60), standing: .ended)])
        await wait { !store.isPro }
        #expect(store.entitlement == .expired(on: now.addingTimeInterval(-60)))
    }

    @Test func aForcedStateReadsNothing() async {
        let source = StubProSource([subscription(ends: now.addingTimeInterval(86_400))])
        let store = ProStore(source: source, forced: .free)
        store.start()
        await store.refresh()

        #expect(store.entitlement == .free)
        #expect(await source.reads == 0)
    }

    @Test func theDebugSwitchNamesEveryState() {
        #expect(ProStore.forcedEntitlement(named: "0", now: now) == .free)
        #expect(ProStore.forcedEntitlement(named: "1", now: now)?.isActive == true)
        #expect(ProStore.forcedEntitlement(named: "lifetime", now: now) == .lifetime(since: now))
        #expect(ProStore.forcedEntitlement(named: "expired", now: now)?.isActive == false)
        #expect(ProStore.forcedEntitlement(named: nil, now: now) == nil)
        #expect(ProStore.forcedEntitlement(named: "yes", now: now) == nil)
    }
}

/// Purchases made in StoreKit's test environment, from the configuration file of the repository: no App Store, no account.
/// A purchase goes through the app's own code. What the test session does behind its back (an expiry, a refund) only
/// reaches a hosted test at the next exchange with the store, so the tests restore the purchases to see it.
/// Each test clears what it bought: a purchase left in the local store is read as real by a Debug app launched
/// afterwards, which then tells the `cumulus` command that Cumulus Pro is active (seen on 13/10/2026).
@Suite(.serialized)
@MainActor
struct ProStoreKitTests {
    private func session() throws -> SKTestSession {
        let url = try #require(Bundle.allBundles.lazy.compactMap { $0.url(forResource: "Cumulus", withExtension: "storekit") }.first)
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @Test func theConfigurationFileSellsTheTwoProductsWithTheFreeMonth() async throws {
        _ = try session()
        let store = ProStore()
        await store.loadOffers()

        #expect(store.offers.map(\.product) == [.yearly, .lifetime])
        #expect(store.offers.first?.trialDays == 30)
        #expect(store.offers.last?.trialDays == nil)
        #expect(store.offers.filter(\.displayPrice.isEmpty).isEmpty)
    }

    @Test func buyingTheSubscriptionStartsTheFreeMonthAndItsEndClosesPro() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = ProStore()
        await store.refresh()
        #expect(store.entitlement == .free)

        #expect(await store.purchase(.yearly) == .purchased)
        guard case .trial(_, let willRenew) = store.entitlement else {
            Issue.record("Expected the free month, got \(store.entitlement)")
            return
        }
        #expect(willRenew && store.allows(.regressions))

        await store.loadOffers()
        #expect(store.offers.first?.trialDays == nil, "The free month is offered once")

        try session.expireSubscription(productIdentifier: ProProduct.yearly.rawValue)
        #expect(await store.restore())
        guard case .expired = store.entitlement else {
            Issue.record("Expected an expired subscription, got \(store.entitlement)")
            return
        }
        #expect(!store.allows(.regressions))
    }

    @Test func theLifetimePurchaseOpensProAndARefundClosesIt() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = ProStore()

        #expect(await store.purchase(.lifetime) == .purchased)
        guard case .lifetime = store.entitlement else {
            Issue.record("Expected the lifetime purchase, got \(store.entitlement)")
            return
        }

        let bought = try #require(session.allTransactions().first { $0.productIdentifier == ProProduct.lifetime.rawValue })
        try session.refundTransaction(identifier: bought.identifier)
        #expect(await store.restore())
        #expect(store.entitlement == .free)
    }

    @Test func theLifetimePurchaseOutlivesASubscriptionThatEnds() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = ProStore()

        #expect(await store.purchase(.yearly) == .purchased)
        #expect(await store.purchase(.lifetime) == .purchased)
        try session.expireSubscription(productIdentifier: ProProduct.yearly.rawValue)
        #expect(await store.restore())

        guard case .lifetime = store.entitlement else {
            Issue.record("Expected the lifetime purchase, got \(store.entitlement)")
            return
        }
    }
}
