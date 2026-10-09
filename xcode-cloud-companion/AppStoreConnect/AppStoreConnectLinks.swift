import Foundation

nonisolated enum AppStoreConnectLinks {
    static let home = URL(string: "https://appstoreconnect.apple.com/")!
    /// Users and Access › Integrations › App Store Connect API (team keys).
    static let integrations = URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!
    /// Xcode Cloud › Usage. App Store Connect shows it under /teams/<team>/access/ci/usage; the team is left out
    /// because the API does not expose it, so the site picks the team the user is signed in to.
    static let xcodeCloudUsage = URL(string: "https://appstoreconnect.apple.com/access/ci/usage")!

    /// Format still to be confirmed on a real build (XCO-9); without an app ID, App Store Connect's home.
    static func build(appID: String?, buildRunID: String) -> URL {
        guard let appID,
              let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/ci/builds/\(buildRunID)/summary")
        else { return home }
        return url
    }
}
