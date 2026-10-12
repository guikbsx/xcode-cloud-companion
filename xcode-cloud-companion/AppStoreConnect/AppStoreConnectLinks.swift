import Foundation

/// App Store Connect's pages live under /teams/<team>/…; without the team they open blank. The team is the
/// API key's Issuer ID. Before a key is known, links fall back to the home page.
nonisolated enum AppStoreConnectLinks {
    static let home = URL(string: "https://appstoreconnect.apple.com/")!

    /// Users and Access › Integrations › App Store Connect API (team keys).
    static func integrations(teamID: String?) -> URL {
        teamPage("access/integrations/api", teamID: teamID) ?? home
    }

    /// Xcode Cloud › Usage.
    static func xcodeCloudUsage(teamID: String?) -> URL {
        teamPage("access/ci/usage", teamID: teamID) ?? home
    }

    /// A build's summary; without an app ID, App Store Connect's home.
    static func build(appID: String?, buildRunID: String, teamID: String?) -> URL {
        guard let appID, isIdentifier(appID), isIdentifier(buildRunID) else { return home }
        let path = "apps/\(appID)/ci/builds/\(buildRunID)/summary"
        return teamPage(path, teamID: teamID) ?? URL(string: "https://appstoreconnect.apple.com/\(path)") ?? home
    }

    /// A workflow's page under the app's Xcode Cloud tab; without an app ID, App Store Connect's home.
    static func workflow(appID: String?, workflowID: String, teamID: String?) -> URL {
        guard let appID, isIdentifier(appID), isIdentifier(workflowID) else { return home }
        let path = "apps/\(appID)/ci/workflows/\(workflowID)"
        return teamPage(path, teamID: teamID) ?? URL(string: "https://appstoreconnect.apple.com/\(path)") ?? home
    }

    private static func teamPage(_ path: String, teamID: String?) -> URL? {
        guard let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), isIdentifier(teamID) else { return nil }
        return URL(string: "https://appstoreconnect.apple.com/teams/\(teamID.lowercased())/\(path)")
    }

    /// Identifiers go into a path as they are: letters, digits and hyphens only.
    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
