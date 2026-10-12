import Foundation

/// A branch, a tag or a pull request, as the builds of the cache name it.
nonisolated enum ReferenceKey: Hashable, Sendable {
    case branchOrTag(String)
    case pullRequest(Int)

    var isPullRequest: Bool {
        if case .pullRequest = self { true } else { false }
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

    var id: ReferenceKey { key }

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

    /// `openPullRequests` is Apple's list when it could be read: a pull request absent from it is closed and left out.
    /// nil means the list is unknown, and every pull request the builds name is shown.
    init(
        snapshot: BuildSnapshot, openPullRequests: [PullRequestReference]?, filter: ReferenceFilter = .all, query: String = "",
        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) {
        let products = Dictionary(snapshot.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workflows = Dictionary(snapshot.workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let open = openPullRequests.map { Dictionary($0.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first }) }

        var newest: [ReferenceKey: CIBuildRun] = [:]
        for run in snapshot.runs {
            guard let key = Self.key(of: run) else { continue }
            if let known = newest[key], Self.order(known) >= Self.order(run) { continue }
            newest[key] = run
        }
        hasNothing = newest.isEmpty

        rows = newest
            .compactMap { key, run -> ReferenceRow? in
                var title: String
                var subtitle: String?
                var webURL: URL?
                switch key {
                case .branchOrTag(let name):
                    guard filter != .pullRequests else { return nil }
                    title = name
                case .pullRequest(let number):
                    guard filter != .branches else { return nil }
                    if let open {
                        guard let pullRequest = open[number] else { return nil }
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
                    webURL: webURL
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
