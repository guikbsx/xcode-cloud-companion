import Foundation
import Observation

/// Apple's list of open pull requests, for the view by branch and pull request: a build of a closed pull request stays in
/// the cache, only this list says the pull request is gone. Read when the view opens, then at most every five minutes.
@Observable
final class ReferencesStore {
    static let freshness: TimeInterval = 5 * 60

    /// nil until the list was read once, or when it could not be: both mean "unknown", not "none".
    private(set) var openPullRequests: OpenPullRequests?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var loadedAt: Date?
    private var repositoriesByWorkflow: [String: String] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let budget: () async -> RateLimit?

    init(client: @escaping () async -> AppStoreConnectClient?, budget: @escaping () async -> RateLimit?) {
        self.client = client
        self.budget = budget
    }

    /// Reads the open pull requests of every repository the pull request builds of `snapshot` come from, unless a
    /// read is fresh enough, one is running, or the key's hourly budget is nearly spent.
    func load(snapshot: BuildSnapshot, now: Date = Date()) async {
        guard !isLoading else { return }
        if let loadedAt, now.timeIntervalSince(loadedAt) < Self.freshness { return }
        let workflowIDs = Set(snapshot.runs.filter { ReferencesModel.key(of: $0)?.isPullRequest == true }.compactMap(\.workflowID))
        guard !workflowIDs.isEmpty else {
            openPullRequests = OpenPullRequests(byRepository: [:])
            loadedAt = now
            return
        }
        guard let client = await client() else { return }
        if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining { return }

        isLoading = true
        defer { isLoading = false }
        var repositories: Set<String> = []
        var failed = false
        for workflowID in workflowIDs.sorted() {
            if let known = repositoriesByWorkflow[workflowID] {
                repositories.insert(known)
            } else if let repository = try? await client.repositoryID(workflowID: workflowID) {
                repositoriesByWorkflow[workflowID] = repository
                repositories.insert(repository)
            } else {
                failed = true
            }
        }
        var found: [String: [PullRequestReference]] = [:]
        for repository in repositories.sorted() {
            if let pullRequests = try? await client.pullRequests(repositoryID: repository) {
                found[repository] = pullRequests
            } else {
                failed = true
            }
        }
        loadFailed = failed
        loadedAt = now
        // A partial list would hide the pull requests of the repository that failed: the list stays unknown.
        if !failed {
            openPullRequests = OpenPullRequests(byRepository: found, repositoryByWorkflow: repositoriesByWorkflow)
        }
    }
}
