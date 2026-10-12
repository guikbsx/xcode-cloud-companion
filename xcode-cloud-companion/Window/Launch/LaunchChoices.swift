import Foundation

/// The three kinds of source a manual build runs on; the sheet shows one kind at a time.
nonisolated enum LaunchSourceKind: String, CaseIterable, Identifiable, Sendable {
    case branch
    case tag
    case pullRequest

    var id: String { rawValue }
}

/// Everything a workflow's repository offers to launch on, read once per session.
nonisolated struct LaunchChoices: Equatable, Sendable {
    /// How many names a menu shows at once: past that, typing narrows the list.
    static let menuLimit = 60
    /// Below this many names there is nothing to narrow.
    static let filterThreshold = 12

    let branches: [GitReference]
    let tags: [GitReference]
    /// nil when the list could not be read, which is not the same as no open pull request.
    let pullRequests: [PullRequestReference]?

    init(references: [GitReference], pullRequests: [PullRequestReference]?) {
        branches = references.filter { $0.kind == .branch }
        tags = references.filter { $0.kind == .tag }
        self.pullRequests = pullRequests
    }

    /// The kind a remembered name belongs to: a tag only when no branch wears the name.
    func kind(of preferredName: String?) -> LaunchSourceKind {
        guard let preferredName, !branches.contains(where: { $0.name == preferredName }) else { return .branch }
        return tags.contains { $0.name == preferredName } ? .tag : .branch
    }

    /// The items whose name contains `query`, the first `menuLimit` only, so a repository with hundreds of branches keeps its menu short.
    static func matching<Item>(_ items: [Item], query: String, name: (Item) -> String) -> (shown: [Item], total: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let found = trimmed.isEmpty ? items : items.filter { name($0).localizedCaseInsensitiveContains(trimmed) }
        return (Array(found.prefix(menuLimit)), found.count)
    }
}

/// What the cache says about a source: the newest run on it, for the line under the menu.
nonisolated enum LaunchSourceHistory {
    static func lastRun(onBranchOrTag name: String, in runs: [CIBuildRun]) -> CIBuildRun? {
        newest(runs.filter { $0.sourceBranchOrTag == name && $0.isPullRequestBuild != true && $0.pullRequestNumber == nil })
    }

    static func lastRun(onPullRequest number: Int, in runs: [CIBuildRun]) -> CIBuildRun? {
        newest(runs.filter { $0.pullRequestNumber == number })
    }

    private static func newest(_ runs: [CIBuildRun]) -> CIBuildRun? {
        runs.max { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
    }
}
