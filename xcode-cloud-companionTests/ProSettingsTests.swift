import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ProSettingsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { now.addingTimeInterval(86_400 * 30) }

    @Test func eachStateOffersWhatItCanDo() {
        #expect(ProSettingsAction.actions(for: .free) == [.purchase, .restore, .redeemCode])
        #expect(ProSettingsAction.actions(for: .expired(on: now)) == [.purchase, .restore, .redeemCode])
        #expect(ProSettingsAction.actions(for: .trial(ends: later, willRenew: true)) == [.manageSubscription])
        #expect(ProSettingsAction.actions(for: .subscribed(until: later, willRenew: false)) == [.manageSubscription])
        #expect(ProSettingsAction.actions(for: .lifetime(since: now)).isEmpty)
    }

    @Test func restoringIsOfferedInEveryStateWithoutPro() {
        let states: [ProEntitlement] = [.free, .expired(on: now), .trial(ends: later, willRenew: true), .subscribed(until: later, willRenew: true), .lifetime(since: now)]
        let missing = states.filter { !$0.isActive && !ProSettingsAction.actions(for: $0).contains(.restore) }
        let offeredWithPro = states.filter { $0.isActive && ProSettingsAction.actions(for: $0).contains(.purchase) }

        #expect(missing.isEmpty && offeredWithPro.isEmpty)
    }

    @Test func thePaneIsADestinationRememberedLikeTheOthers() throws {
        let suite = "ProSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = TestAccounts()

        let navigation = SettingsNavigationModel(defaults: defaults)
        navigation.select(.pro, among: accounts.model)
        #expect(navigation.pane == .pro && navigation.destination == .pro)
        #expect(SettingsNavigationModel(defaults: defaults).pane == .pro)
        #expect(SettingsNavigationModel.Pane(rawValue: "pro") == .pro, "XCC_SETTINGS=pro opens the pane")
    }

    @Test func theTrialSaysWhenItEndsAndWhatHappensThen() {
        let english = Locale(identifier: "en_US")
        let trial = ProEntitlement.trial(ends: later, willRenew: true)

        #expect(ProEntitlementText.title(trial, locale: english) == "Free trial, until \(ProEntitlementText.day(later, locale: english))")
        #expect(ProEntitlementText.detail(trial, locale: english) == "The yearly subscription starts then. Nothing is charged before that date.")
        #expect(ProEntitlementText.detail(.lifetime(since: now), locale: english) == "Bought on \(ProEntitlementText.day(now, locale: english)). Nothing to renew.")
    }
}
