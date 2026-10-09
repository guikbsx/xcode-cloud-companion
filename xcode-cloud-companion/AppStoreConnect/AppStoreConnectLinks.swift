import Foundation

nonisolated enum AppStoreConnectLinks {
    static let home = URL(string: "https://appstoreconnect.apple.com/")!
    /// To replace with the exact address of Xcode Cloud › Usage once read from the browser.
    static let xcodeCloudUsage = home

    /// Format still to be confirmed on a real build (XCO-9); without an app ID, App Store Connect's home.
    static func build(appID: String?, buildRunID: String) -> URL {
        guard let appID,
              let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/ci/builds/\(buildRunID)/summary")
        else { return home }
        return url
    }
}
