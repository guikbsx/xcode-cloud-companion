import AppKit
import Testing
@testable import XcodeCloudCompanion

struct SettingsGuidesTests {
    @Test func theIssuerIDShowsOnlyItsEnds() {
        let masked = ConfigurationSettingsView.masked("69a6de7f-1234-5678-9abc-def012343c1a")

        #expect(masked == "69a6de7f-••••-••••-••••-••••••••3c1a")
        #expect(!masked.contains("1234"))
    }

    @Test func aShortIdentifierIsHiddenWhole() {
        #expect(ConfigurationSettingsView.masked("abc") == "•••")
        #expect(ConfigurationSettingsView.masked("") == "")
    }

    @Test func theUsageLinkOpensXcodeCloudUsageNotTheHomePage() {
        #expect(AppStoreConnectLinks.xcodeCloudUsage.absoluteString == "https://appstoreconnect.apple.com/access/ci/usage")
        #expect(AppStoreConnectLinks.xcodeCloudUsage != AppStoreConnectLinks.home)
    }

    @Test func theIntegrationsLinkPointsToTheTeamKeysPage() {
        #expect(AppStoreConnectLinks.integrations.absoluteString == "https://appstoreconnect.apple.com/access/integrations/api")
    }
}
