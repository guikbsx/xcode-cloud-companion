import Foundation
import Observation

enum SidebarSelection: Hashable {
    case overview
    case allBuilds
    case product(String)
    case workflow(String)
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

    /// Every build is in "All builds", whatever app or workflow was picked before.
    func showBuild(_ id: String) {
        sidebarSelection = .allBuilds
        selectedBuildID = id
    }

    /// Opens what a `cumulus://` address names; anything else is ignored.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let destination = CumulusURL.destination(of: url) else { return false }
        switch destination {
        case .build(let id): showBuild(id)
        }
        return true
    }
}

/// `cumulus://build/<buildRunID>`: read-only, no address ever launches or changes anything.
nonisolated enum CumulusURL {
    static let scheme = "cumulus"

    enum Destination: Equatable {
        case build(String)
    }

    static func build(id: String) -> URL? {
        guard isValid(id: id) else { return nil }
        return URL(string: "\(scheme)://build/\(id)")
    }

    static func destination(of url: URL) -> Destination? {
        guard url.scheme == scheme, url.host() == "build" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, isValid(id: parts[0]) else { return nil }
        return .build(parts[0])
    }

    /// Build run identifiers are UUIDs: nothing else is accepted.
    private static func isValid(id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
