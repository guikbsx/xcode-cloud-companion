import Foundation
import Observation

enum SidebarSelection: Hashable {
    case overview
    case allBuilds
    case product(String)
    case workflow(String)
}

/// The tabs of a build sheet.
nonisolated enum BuildTab: Hashable, Sendable {
    case actions, tests, problems, artifacts
}

/// Where the main window is looking; the menu and the URL scheme drive it as well as the clicks.
@Observable
final class NavigationModel {
    /// Picking something else in the sidebar clears the build, so the right column shows what was picked.
    var sidebarSelection: SidebarSelection = .allBuilds {
        didSet {
            if oldValue != sidebarSelection { selectedBuildID = nil }
        }
    }
    var selectedBuildID: String?
    /// The tab the build sheet shows; it stays as the user left it from one build to the next.
    var buildTab = BuildTab.actions

    /// Every build is in "All builds", whatever app or workflow was picked before.
    func showBuild(_ id: String, tab: BuildTab? = nil) {
        sidebarSelection = .allBuilds
        selectedBuildID = id
        if let tab {
            buildTab = tab
        }
    }

    /// Another account is on screen: an app, a workflow or a build of the one before means nothing in it.
    func accountDidChange() {
        switch sidebarSelection {
        case .product, .workflow: sidebarSelection = .allBuilds
        case .overview, .allBuilds: selectedBuildID = nil
        }
    }

    /// Opens what a `cumulus://` address names; anything else is ignored.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let destination = CumulusURL.destination(of: url) else { return false }
        switch destination {
        case .build(let id): showBuild(id)
        case .overview: sidebarSelection = .overview
        }
        return true
    }
}

/// `cumulus://build/<buildRunID>` and `cumulus://overview`, which may name its account (`?account=<id>`): read-only,
/// no address ever launches or changes anything.
nonisolated enum CumulusURL {
    static let scheme = "cumulus"

    enum Destination: Equatable {
        /// A build names itself alone: the app finds the account that holds it.
        case build(String)
        case overview(accountID: String?)
    }

    static let overview = URL(string: "\(scheme)://overview")

    static func overview(accountID: String?) -> URL? {
        guard let accountID, Account.isValid(id: accountID) else { return overview }
        return URL(string: "\(scheme)://overview?account=\(accountID)")
    }

    static func build(id: String) -> URL? {
        guard isValid(id: id) else { return nil }
        return URL(string: "\(scheme)://build/\(id)")
    }

    static func destination(of url: URL) -> Destination? {
        guard url.scheme == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host() == "overview" {
            guard parts.isEmpty else { return nil }
            let account = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "account" }?.value
            return .overview(accountID: account.flatMap { Account.isValid(id: $0) ? $0 : nil })
        }
        guard url.host() == "build" else { return nil }
        guard parts.count == 1, isValid(id: parts[0]) else { return nil }
        return .build(parts[0])
    }

    /// Build run identifiers are UUIDs: nothing else is accepted.
    private static func isValid(id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
