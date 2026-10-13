import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ProLockTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func access(_ entitlement: ProEntitlement, asked: @escaping (ProFeature) -> Void = { _ in }) -> ProAccess {
        ProAccess(store: ProStore(source: StubProSource(), forced: entitlement), purchase: asked)
    }

    @Test func everyFunctionIsRefusedWithoutProAndOpenWithIt() {
        let free = access(.free)
        let expired = access(.expired(on: now.addingTimeInterval(-86_400)))
        let trial = access(.trial(ends: now.addingTimeInterval(86_400), willRenew: true))
        let lifetime = access(.lifetime(since: now))

        for feature in ProFeature.allCases {
            #expect(!free.allows(feature), "\(feature) is open without Pro")
            #expect(!expired.allows(feature), "\(feature) stays open after Pro ended")
            #expect(trial.allows(feature), "\(feature) is closed during the trial")
            #expect(lifetime.allows(feature), "\(feature) is closed with Pro")
        }
    }

    @Test func aViewWithoutAccessTreatsEverythingAsOpen() {
        let none: ProAccess? = nil
        #expect(ProFeature.allCases.allSatisfy { none.allows($0) })
    }

    @Test func everyFunctionHasANameAndASentenceOfItsOwn() {
        let titles = ProFeature.allCases.map(ProFeatureText.title)
        let sentences = ProFeature.allCases.map(ProFeatureText.sentence)

        #expect(titles.allSatisfy { !$0.isEmpty } && Set(titles).count == titles.count)
        #expect(sentences.allSatisfy { $0.hasSuffix(".") } && Set(sentences).count == sentences.count)
    }

    @Test func aLockedFunctionLeadsToThePurchaseSheetOpenedOnIt() {
        var asked: [ProFeature] = []
        let free = access(.free) { asked.append($0) }

        free.showPurchase(for: .regressions)
        free.showPurchase(for: .pauseWorkflow)

        #expect(asked == [.regressions, .pauseWorkflow])
        #expect(ProBenefit.ordered(for: .regressions).first == .diagnostics)
        #expect(ProBenefit.ordered(for: .pauseWorkflow).first == .workflows)
    }

    @Test func anAccountAddedLaterIsGivenCumulusProToo() async throws {
        let accounts = TestAccounts()
        let store = ProStore(source: StubProSource(), forced: .free)
        accounts.model.pro = store

        let session = try await accounts.model.add(name: "Personal", credentials: TestAccounts.credentials)

        #expect(session.pro === store)
    }
}
