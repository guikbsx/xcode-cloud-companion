import Foundation

nonisolated enum BuildFilter: CaseIterable, Hashable, Sendable {
    case all, running, failed, testFlight
}

/// One build of the list, flattened to what a row shows.
nonisolated struct BuildRowData: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int?
    let status: BuildStatus
    let createdDate: Date?
    let startedDate: Date?
    let finishedDate: Date?
    let productName: String
    let workflowName: String?
    let reference: String?
    let failedTests: Int
    let shipsToTestFlight: Bool
    let commitSha: String?
    /// The Xcode Cloud product name, still found by the search when the row shows the Store name.
    var productKey: String?

    var numberText: String { number.map { "#\($0)" } ?? "#?" }

    /// A long Store name is cut like in the menu, so it leaves the workflow and the branch their room.
    var detail: String {
        UsageFormat.dotted([CIProduct.compact(productName), workflowName, reference].compactMap(\.self))
    }

    /// The same line with the app's whole name, for VoiceOver.
    var spokenDetail: String {
        UsageFormat.dotted([productName, workflowName, reference].compactMap(\.self))
    }

    /// How it went, in words: “Failed · 3 tests”, “Succeeded · TestFlight”, “Running · 4 min”.
    func summary(now: Date) -> String {
        switch status {
        case .running:
            let elapsed = (startedDate ?? createdDate).map { max(0, now.timeIntervalSince($0)) }
            guard let elapsed else { return status.label }
            return UsageFormat.dotted([status.label, UsageFormat.minutes(elapsed / 60)])
        case .failed where failedTests > 0:
            return UsageFormat.dotted([status.label, String(localized: "\(failedTests) tests", comment: "Number of failed tests of a build, in the build list")])
        case .succeeded where shipsToTestFlight:
            return UsageFormat.dotted([status.label, "TestFlight"])
        default:
            return status.label
        }
    }

    /// Elapsed time of a running build, total time of a finished one; nothing for a build that never started.
    func duration(now: Date) -> String? {
        guard let startedDate else { return nil }
        return Self.clock(max(0, (finishedDate ?? now).timeIntervalSince(startedDate)))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
        if let number, !digits.isEmpty, digits.allSatisfy(\.isNumber), String(number).hasPrefix(digits) { return true }
        if query.count >= 3, let commitSha, commitSha.lowercased().hasPrefix(query) { return true }
        return [productName, productKey, workflowName, reference].compactMap(\.self).contains { $0.lowercased().contains(query) }
    }
}

nonisolated struct BuildDayGroup: Identifiable, Equatable, Sendable {
    enum Key: Hashable, Sendable {
        case today, yesterday, thisWeek, month(year: Int, month: Int), unknown
    }

    let key: Key
    let title: String
    let rows: [BuildRowData]

    var id: Key { key }
}

nonisolated enum BuildListEmptyReason: Equatable, Sendable {
    case noBuilds
    case nothingMatches
}

/// The middle column: the builds of the sidebar's selection, filtered, searched and grouped by day.
nonisolated struct BuildListModel: Equatable, Sendable {
    var title: String
    var groups: [BuildDayGroup]
    var emptyReason: BuildListEmptyReason?

    /// The list is a workflow's, and Apple says that workflow is paused.
    var isPausedWorkflow = false

    var rows: [BuildRowData] { groups.flatMap(\.rows) }
    var count: Int { groups.reduce(0) { $0 + $1.rows.count } }

    init(
        snapshot: BuildSnapshot, scope: SidebarSelection, filter: BuildFilter = .all, query: String = "",
        now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) {
        let products = Dictionary(snapshot.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workflows = Dictionary(snapshot.workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let scoped: [CIBuildRun]
        switch scope {
        case .overview, .allBuilds:
            title = String(localized: "All builds")
            scoped = snapshot.runs
        case .product(let id):
            title = products[id]?.displayName ?? String(localized: "All builds")
            scoped = snapshot.runs(forProductID: id)
        case .workflow(let id):
            isPausedWorkflow = workflows[id]?.isEnabled == false
            title = workflows[id]?.name ?? String(localized: "All builds")
            scoped = snapshot.runs.filter { $0.workflowID == id }
        }

        let rows = scoped
            .sorted { ($0.createdDate ?? .distantPast, $0.number ?? 0) > ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            .map { run in
                BuildRowData(
                    id: run.id, number: run.number, status: BuildStatus(run: run), createdDate: run.createdDate,
                    startedDate: run.startedDate, finishedDate: run.finishedDate,
                    productName: products[run.productID]?.displayName ?? "?", workflowName: run.workflowName ?? run.workflowID.flatMap { workflows[$0]?.name },
                    reference: Self.reference(of: run), failedTests: run.issueCounts?.testFailures ?? 0,
                    shipsToTestFlight: run.workflowID.flatMap { workflows[$0] }?.shipsToTestFlight ?? false,
                    commitSha: run.sourceCommit?.commitSha, productKey: products[run.productID]?.name
                )
            }
            .filter { Self.passes($0, filter) && $0.matches(query) }

        var order: [BuildDayGroup.Key] = []
        var byKey: [BuildDayGroup.Key: [BuildRowData]] = [:]
        for row in rows {
            let key = Self.key(for: row.createdDate, now: now, calendar: calendar)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
        }
        groups = order.map { key in
            BuildDayGroup(key: key, title: Self.title(of: key, calendar: calendar, locale: locale), rows: byKey[key] ?? [])
        }
        emptyReason = rows.isEmpty ? (scoped.isEmpty && filter == .all && query.isEmpty ? .noBuilds : .nothingMatches) : nil
    }

    private static func reference(of run: CIBuildRun) -> String? {
        if run.isPullRequestBuild == true {
            return run.pullRequestNumber.map { String(localized: "PR #\($0)", comment: "A pull request, in a build's line") }
        }
        return run.sourceBranchOrTag
    }

    private static func passes(_ row: BuildRowData, _ filter: BuildFilter) -> Bool {
        switch filter {
        case .all: true
        case .running: row.status == .running
        case .failed: row.status == .failed || row.status == .errored
        case .testFlight: row.shipsToTestFlight
        }
    }

    static func key(for date: Date?, now: Date, calendar: Calendar) -> BuildDayGroup.Key {
        guard let date else { return .unknown }
        if date >= calendar.startOfDay(for: now) || date > now { return .today }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        if date >= yesterday { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    private static func title(of key: BuildDayGroup.Key, calendar: Calendar, locale: Locale) -> String {
        switch key {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .thisWeek: String(localized: "This week")
        case .unknown: String(localized: "Undated")
        case .month(let year, let month):
            calendar.date(from: DateComponents(year: year, month: month)).map {
                $0.formatted(.dateTime.month(.wide).year().locale(locale))
            } ?? ""
        }
    }
}

nonisolated extension CIWorkflow {
    /// A workflow with an action that hands its archive to TestFlight testers.
    var shipsToTestFlight: Bool {
        actions.contains { !($0.buildDistributionAudience ?? "").isEmpty }
    }
}
