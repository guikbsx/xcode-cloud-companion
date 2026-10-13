import AppKit
import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ProPurchaseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")
    private let yearly = ProOffer(product: .yearly, displayName: "Cumulus Pro Yearly", displayPrice: "€19.99", trialDays: 30)
    private let lifetime = ProOffer(product: .lifetime, displayName: "Cumulus Pro Lifetime", displayPrice: "€59.99", trialDays: nil)

    private var subscribed: [ProReading] {
        [.verified(ProTransaction(product: .yearly, purchaseDate: now, expirationDate: now.addingTimeInterval(86_400 * 30), isTrial: true))]
    }

    private final class Closing {
        var count = 0
    }

    private func model(_ source: StubProSource, origin: ProFeature? = nil, closing: Closing = Closing()) -> ProPurchaseModel {
        ProPurchaseModel(store: ProStore(source: source, now: { self.now }), origin: origin) { closing.count += 1 }
    }

    @Test func thePricesAreTheOnesTheAppStoreGave() async {
        let model = model(StubProSource(offers: [yearly, lifetime]))
        await model.load()

        #expect(model.phase == .ready)
        #expect(model.offers.map(\.displayPrice) == ["€19.99", "€59.99"])
        #expect(model.selectedOffer?.product == .yearly)
    }

    @Test func theFreeMonthIsOnlyOfferedToWhoMayTakeIt() {
        var used = yearly
        used.trialDays = nil

        #expect(ProPurchaseText.buttonTitle(for: yearly, locale: english) == "Try Free for 1 month")
        #expect(ProPurchaseText.buttonTitle(for: used, locale: english) == "Subscribe for €19.99 per Year")
        #expect(ProPurchaseText.buttonTitle(for: lifetime, locale: english) == "Buy for €59.99")
        #expect(ProPurchaseText.tagline(for: yearly, locale: english) == "1 month free trial")
        #expect(ProPurchaseText.tagline(for: used, locale: english) == "Renewed every year")
    }

    @Test func theSubscriptionSaysItsPriceItsRenewalAndHowToStopIt() {
        var used = yearly
        used.trialDays = nil

        for text in [ProPurchaseText.finePrint(for: yearly), ProPurchaseText.finePrint(for: used)] {
            #expect(text.contains("€19.99") && text.contains("per year") && text.contains("renewed automatically") && text.contains("Cancel"))
        }
        #expect(ProPurchaseText.finePrint(for: lifetime) == "One payment. No subscription.")
    }

    @Test func withoutProductsNothingIsOfferedForSale() async {
        let source = StubProSource()
        let model = model(source)
        await model.load()

        #expect(model.phase == .unavailable)
        #expect(model.selectedOffer == nil)
        await model.buy()
        #expect(await source.purchases.isEmpty)

        await source.setOffers([yearly, lifetime])
        await model.load()
        #expect(model.phase == .ready)
    }

    @Test func aPurchaseThatWentThroughClosesTheSheetAndOpensPro() async {
        let closing = Closing()
        let source = StubProSource(offers: [yearly, lifetime], purchase: .purchased, afterPurchase: subscribed)
        let model = model(source, origin: .regressions, closing: closing)
        await model.load()
        await model.buy()

        #expect(closing.count == 1)
        #expect(model.store.allows(.regressions))
        #expect(await source.purchases == [.yearly])
    }

    @Test func aCancelledPurchaseLeavesTheSheetWithoutAnError() async {
        let closing = Closing()
        let model = model(StubProSource(offers: [yearly, lifetime], purchase: .cancelled), closing: closing)
        await model.load()
        model.selection = .lifetime
        await model.buy()

        #expect(model.phase == .ready && closing.count == 0)
        #expect(!model.store.isPro)
    }

    @Test func aPurchaseWaitingForApprovalSaysSoAndOpensNothing() async {
        let closing = Closing()
        let model = model(StubProSource(offers: [yearly, lifetime], purchase: .pending), closing: closing)
        await model.load()
        await model.buy()

        #expect(model.phase == .pending && closing.count == 0)
        #expect(!model.store.isPro)
    }

    @Test func aRefusedPurchaseShowsTheWordsOfTheAppStore() async {
        let model = model(StubProSource(offers: [yearly], purchase: .failed("Payment declined")))
        await model.load()
        await model.buy()

        #expect(model.phase == .failed("Payment declined"))
    }

    @Test func theBenefitOneCameForIsReadFirst() {
        #expect(ProBenefit.ordered(for: nil) == ProBenefit.allCases)
        #expect(ProBenefit.ordered(for: .mcpServer).first == .agents)
        #expect(ProBenefit.ordered(for: .multipleAccounts).first == .accounts)
        #expect(ProBenefit.ordered(for: .testHealth).first == .diagnostics)
        #expect(Set(ProBenefit.ordered(for: .pauseWorkflow)) == Set(ProBenefit.allCases))
    }

    @Test func everyProFeatureBelongsToABenefit() {
        let covered = Set(ProBenefit.allCases.flatMap(\.features))
        let orphans = ProFeature.allCases.filter { !covered.contains($0) }

        #expect(orphans.isEmpty)
    }

    @Test func whoAlreadyHasProSeesTheirStateNotAnOffer() async {
        let source = StubProSource(subscribed, offers: [yearly, lifetime])
        let model = model(source)
        await model.store.refresh()
        await model.load()

        #expect(model.store.isPro && model.phase == .ready)
        #expect(model.offers.isEmpty, "No price is asked for when there is nothing to sell")
        #expect(ProEntitlementText.title(model.store.entitlement, locale: english).hasPrefix("Free trial, until"))
    }

    @Test func aRestoreThatFindsNothingSaysSo() async {
        let closing = Closing()
        let model = model(StubProSource(offers: [yearly]), closing: closing)
        await model.load()
        await model.restore()

        #expect(model.restoreNote == "No Cumulus Pro purchase was found for this Apple Account.")
        #expect(closing.count == 0)

        let offline = self.model(StubProSource(offers: [yearly], restoreAnswers: false))
        await offline.restore()
        #expect(offline.restoreNote == "The App Store could not be reached. Try again in a moment.")
    }

    @Test func aRestoreThatFindsProClosesTheSheet() async {
        let closing = Closing()
        let model = model(StubProSource(subscribed, offers: [yearly]), closing: closing)
        await model.load()
        await model.restore()

        #expect(closing.count == 1 && model.store.isPro)
    }

    @Test func everyStateOfProHasItsWords() {
        let end = now.addingTimeInterval(86_400 * 30)

        #expect(ProEntitlementText.title(.free, locale: english) == "Free version")
        #expect(ProEntitlementText.title(.subscribed(until: end, willRenew: true), locale: english) == "Cumulus Pro, yearly")
        #expect(ProEntitlementText.detail(.subscribed(until: end, willRenew: true), locale: english).hasPrefix("Renews on"))
        #expect(ProEntitlementText.detail(.subscribed(until: end, willRenew: false), locale: english).hasPrefix("Renewal is off"))
        #expect(ProEntitlementText.title(.lifetime(since: now), locale: english) == "Cumulus Pro, lifetime")
        #expect(ProEntitlementText.title(.expired(on: now), locale: english).hasPrefix("Cumulus Pro ended on"))
        #expect(ProEntitlementText.detail(.expired(on: now), locale: english).hasPrefix("Nothing is erased"))
    }

    @Test func theSheetHangsOnAWindowAndOpensOnlyOnce() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        // A window made in code is released by its own close unless told otherwise: Swift would release it a second time.
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let presenter = ProPurchasePresenter(store: ProStore(source: StubProSource(offers: [yearly, lifetime]), now: { self.now }))

        parent.orderFront(nil)
        presenter.present(over: parent, origin: .regressions)
        for _ in 0..<100 where parent.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sheet = try #require(parent.attachedSheet)
        presenter.present(over: parent)
        #expect(parent.attachedSheet === sheet && presenter.isPresenting)

        parent.endSheet(sheet)
        for _ in 0..<100 where presenter.isPresenting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!presenter.isPresenting)
    }
}
