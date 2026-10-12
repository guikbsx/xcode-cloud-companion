import AppKit
import Testing
@testable import XcodeCloudCompanion

struct SettingsGuidesTests {
    @Test func theIssuerIDShowsOnlyItsEnds() {
        let masked = AccountDetailView.masked("69a6de7f-1234-5678-9abc-def012343c1a")

        #expect(masked == "69a6de7f-••••-••••-••••-••••••••3c1a")
        #expect(!masked.contains("1234"))
    }

    @Test func aShortIdentifierIsHiddenWhole() {
        #expect(AccountDetailView.masked("abc") == "•••")
        #expect(AccountDetailView.masked("") == "")
    }

    private let team = "69a6de7f-1234-5678-9abc-def012343c1a"

    @Test func pagesLiveUnderTheTeamWhichIsTheIssuerID() {
        #expect(AppStoreConnectLinks.xcodeCloudUsage(teamID: team).absoluteString == "https://appstoreconnect.apple.com/teams/\(team)/access/ci/usage")
        #expect(AppStoreConnectLinks.integrations(teamID: team).absoluteString == "https://appstoreconnect.apple.com/teams/\(team)/access/integrations/api")
        #expect(AppStoreConnectLinks.build(appID: "123", buildRunID: "abc-1", teamID: team).absoluteString == "https://appstoreconnect.apple.com/teams/\(team)/apps/123/ci/builds/abc-1/summary")
    }

    @Test func withoutATeamLinksFallBackToThePagesThatOpen() {
        #expect(AppStoreConnectLinks.xcodeCloudUsage(teamID: nil) == AppStoreConnectLinks.home)
        #expect(AppStoreConnectLinks.integrations(teamID: "") == AppStoreConnectLinks.home)
        #expect(AppStoreConnectLinks.build(appID: "123", buildRunID: "abc", teamID: nil).absoluteString == "https://appstoreconnect.apple.com/apps/123/ci/builds/abc/summary")
        #expect(AppStoreConnectLinks.build(appID: nil, buildRunID: "abc", teamID: team) == AppStoreConnectLinks.home)
    }

    @Test func anIdentifierCannotRewriteThePath() {
        #expect(AppStoreConnectLinks.xcodeCloudUsage(teamID: "../evil") == AppStoreConnectLinks.home)
        #expect(AppStoreConnectLinks.build(appID: "1/2", buildRunID: "abc", teamID: team) == AppStoreConnectLinks.home)
    }

    @MainActor @Test func theWindowsSubtitleSaysHowTheAccountStands() {
        #expect(AccountDetailView.stateText(health: .connected, connection: .connected(productNames: ["A", "B"])) == "Connected · 2 Xcode Cloud apps found")
        #expect(AccountDetailView.stateText(health: .connected, connection: .idle) == "Connected")
        #expect(AccountDetailView.stateText(health: .missingResetDate, connection: .connected(productNames: [])) == "Reset date missing", "what is missing comes first")
        #expect(AccountDetailView.stateText(health: .connected, connection: .failed("401")) == "Key refused")
        #expect(AccountDetailView.stateText(health: .connected, connection: .testing) == "Contacting App Store Connect…")
    }

    @Test func theVersionIsReadFromTheBundleAndLeftOutWhenItSaysNothing() {
        #expect(GeneralSettingsView.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "45"]) == "Version 1.2 (45)")
        #expect(GeneralSettingsView.versionText(info: ["CFBundleShortVersionString": "1.2"]) == "Version 1.2")
        #expect(GeneralSettingsView.versionText(info: ["CFBundleVersion": "45"]) == nil)
        #expect(GeneralSettingsView.versionText(info: nil) == nil)
    }

    @Test func theFreshnessOfTheBuildsIsSaidInTheSidebarsWords() {
        let now = Date(timeIntervalSince1970: 1_791_741_600)
        #expect(SyncActivityView.updatedText(lastSync: now.addingTimeInterval(-120), now: now) == "Updated 2 minutes ago")
        #expect(SyncActivityView.updatedText(lastSync: nil, now: now) == "Not updated yet")
    }
}
