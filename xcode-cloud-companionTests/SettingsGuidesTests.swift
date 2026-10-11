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
}
