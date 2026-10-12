import Foundation

/// A branch, a tag or a pull request, as the builds of the cache name it.
nonisolated enum ReferenceKey: Hashable, Sendable {
    case branchOrTag(String)
    case pullRequest(Int)

    var isPullRequest: Bool {
        if case .pullRequest = self { true } else { false }
    }
}

/// A reference of one app: an app's “main” is not another's, and a pull request's number means nothing outside its app.
nonisolated struct AppReference: Hashable, Sendable {
    let productID: String
    let key: ReferenceKey
}

/// Apple's open pull requests, repository by repository: two repositories may each have a pull request of the same number.
nonisolated struct OpenPullRequests: Equatable, Sendable, ExpressibleByArrayLiteral {
    var byRepository: [String: [PullRequestReference]] = [:]
    /// The repository each workflow builds from.
    var repositoryByWorkflow: [String: String] = [:]

    init(byRepository: [String: [PullRequestReference]] = [:], repositoryByWorkflow: [String: String] = [:]) {
        self.byRepository = byRepository
        self.repositoryByWorkflow = repositoryByWorkflow
    }

    /// One list, of a repository left unnamed: every workflow is looked up in it.
    init(arrayLiteral elements: PullRequestReference...) {
        byRepository = elements.isEmpty ? [:] : ["": elements]
    }

    var all: [PullRequestReference] {
        byRepository.keys.sorted().flatMap { byRepository[$0] ?? [] }
    }

    var isEmpty: Bool {
        byRepository.values.allSatisfy(\.isEmpty)
    }

    /// The open pull request of that number in the repository the workflow builds from; in any repository while the
    /// workflow's own is not known.
    func pullRequest(_ number: Int, workflowID: String?) -> PullRequestReference? {
        if let workflowID, let repository = repositoryByWorkflow[workflowID] {
            return byRepository[repository]?.first { $0.number == number }
        }
        return all.first { $0.number == number }
    }
}

nonisolated enum ReferenceFilter: CaseIterable, Hashable, Sendable {
    case all, pullRequests, branches
}

/// One line of the view: a reference and its newest build.
nonisolated struct ReferenceRow: Identifiable, Equatable, Sendable {
    let key: ReferenceKey
    /// “main”, or “#131 Fix the CSV import”.
    let title: String
    /// A pull request's branches: “fix/csv-import into main”.
    let subtitle: String?
    let lastRun: CIBuildRun
    let status: BuildStatus
    let productName: String
    let workflowName: String?
    let webURL: URL?
    /// The Xcode Cloud product name: the key of the app's colour.
    var productKey: String?
    /// The app the reference belongs to.
    var productID = ""

    var reference: AppReference { AppReference(productID: productID, key: key) }
    var id: AppReference { reference }

    /// What follows the state on the card: the workflow, the build, and a pull request's branches.
    var facts: String {
        UsageFormat.dotted([workflowName, lastRun.number.map { "#\($0)" }, subtitle].compactMap(\.self))
    }

    /// Where a running build's counter starts; nil once it ended.
    var runningSince: Date? {
        status == .running && lastRun.finishedDate == nil ? lastRun.startedDate : nil
    }

    /// “Succeeded · Cumulus · Release · #394”, like a build's line.
    var detail: String {
        let build = lastRun.number.map { "#\($0)" }
        return UsageFormat.dotted([status.label, CIProduct.compact(productName), workflowName, build].compactMap(\.self))
    }

    /// The same line with the app's whole name and the branches of a pull request, for VoiceOver.
    var spokenDetail: String {
        UsageFormat.dotted([status.label, productName, workflowName, lastRun.number.map { "#\($0)" }, subtitle].compactMap(\.self))
    }

    /// How long ago the last build was created, for the right of the card; a running one shows its duration instead.
    func age(now: Date) -> String? {
        lastRun.createdDate.map { UsageFormat.age(since: $0, now: now) }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [title, subtitle, workflowName, productName].compactMap(\.self).contains { $0.lowercased().contains(query) }
    }
}

/// The references whose last build is from the same day, under the same header as the build list's.
nonisolated struct ReferenceGroup: Identifiable, Equatable, Sendable {
    let key: BuildDayGroup.Key
    let title: String
    let rows: [ReferenceRow]

    var id: BuildDayGroup.Key { key }
}

/// The references the cache knows, each with its newest build: what the window shows under “Branches and pull requests”.
nonisolated struct ReferencesModel: Equatable, Sendable {
    let rows: [ReferenceRow]
    /// The rows by day of their last build, newest day first.
    let groups: [ReferenceGroup]
    /// True when the cache holds no reference at all, whatever the filter and the search.
    let hasNothing: Bool

    /// A reference belongs to its app: two apps that both build “main” have a row each.
    /// `openPullRequests` is Apple's list when it could be read: a pull request absent from it is closed and left out.
    /// nil means the list is unknown, and every pull request the builds name is shown.
    init(
        snapshot: BuildSnapshot, openPullRequests: OpenPullRequests?, filter: ReferenceFilter = .all, query: String = "",
        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) {
        let products = Dictionary(snapshot.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workflows = Dictionary(snapshot.workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var newest: [AppReference: CIBuildRun] = [:]
        for run in snapshot.runs {
            guard let key = Self.key(of: run) else { continue }
            let reference = AppReference(productID: run.productID, key: key)
            if let known = newest[reference], Self.order(known) >= Self.order(run) { continue }
            newest[reference] = run
        }
        hasNothing = newest.isEmpty

        rows = newest
            .compactMap { reference, run -> ReferenceRow? in
                let key = reference.key
                var title: String
                var subtitle: String?
                var webURL: URL?
                switch key {
                case .branchOrTag(let name):
                    guard filter != .pullRequests else { return nil }
                    title = name
                case .pullRequest(let number):
                    guard filter != .branches else { return nil }
                    if let openPullRequests {
                        guard let pullRequest = openPullRequests.pullRequest(number, workflowID: run.workflowID) else { return nil }
                        title = pullRequest.label
                        webURL = pullRequest.webURL
                        if let source = pullRequest.sourceBranch, let destination = pullRequest.destinationBranch {
                            subtitle = String(localized: "\(source) into \(destination)", comment: "The two branches of a pull request: the source branch, then the one it goes into.")
                        }
                    } else {
                        title = run.pullRequestTitle.flatMap(\.nilIfBlank).map { "#\(number) \($0)" } ?? "#\(number)"
                    }
                }
                return ReferenceRow(
                    key: key, title: title, subtitle: subtitle, lastRun: run, status: BuildStatus(run: run),
                    productName: products[run.productID]?.displayName ?? "?",
                    workflowName: run.workflowName ?? run.workflowID.flatMap { workflows[$0]?.name },
                    webURL: webURL, productKey: products[run.productID]?.name, productID: run.productID
                )
            }
            .filter { $0.matches(query) }
            .sorted { Self.order($0.lastRun) > Self.order($1.lastRun) }

        var order: [BuildDayGroup.Key] = []
        var byKey: [BuildDayGroup.Key: [ReferenceRow]] = [:]
        for row in rows {
            let key = BuildListModel.key(for: row.lastRun.createdDate, now: now, calendar: calendar)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
        }
        groups = order.map { key in
            ReferenceGroup(key: key, title: BuildListModel.title(of: key, calendar: calendar, locale: locale), rows: byKey[key] ?? [])
        }
    }

    /// Builds of a pull request count for the pull request, never for the branch they came from.
    static func key(of run: CIBuildRun) -> ReferenceKey? {
        if run.isPullRequestBuild == true || run.pullRequestNumber != nil {
            return run.pullRequestNumber.map { .pullRequest($0) }
        }
        return run.sourceBranchOrTag.flatMap(\.nilIfBlank).map { .branchOrTag($0) }
    }

    private static func order(_ run: CIBuildRun) -> (Date, Int) {
        (run.createdDate ?? .distantPast, run.number ?? 0)
    }
}
