import Foundation

nonisolated extension CITestStatus {
    /// The state shown in the badge: the same dots and shapes as builds.
    var buildStatus: BuildStatus {
        switch self {
        case .success: .succeeded
        case .failure: .failed
        case .mixed: .errored
        case .skipped: .skipped
        case .expectedFailure, .unknown: .finished
        }
    }

    var label: String {
        switch self {
        case .success: String(localized: "Passed")
        case .failure: String(localized: "Failed")
        case .mixed: String(localized: "Mixed")
        case .skipped: String(localized: "Skipped")
        case .expectedFailure: String(localized: "Expected failure")
        case .unknown(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

nonisolated enum TestStatusFilter: CaseIterable, Hashable, Sendable {
    case all, failed, passed, skipped, expectedFailure

    func includes(_ status: CITestStatus) -> Bool {
        switch self {
        case .all: true
        case .failed: status.isFailure
        case .passed: status == .success
        case .skipped: status == .skipped
        case .expectedFailure: status == .expectedFailure
        }
    }
}

nonisolated struct TestRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: CITestStatus
    let duration: String?
    let message: String?
    let location: String?
    let path: String?
    let line: Int?
    let devices: [CITestDeviceResult]

    /// The rows of the Tests tab's skeleton: names of a typical length, none of them detailed.
    static let placeholders: [TestRow] = [
        ("testSavingASettingKeepsItsValue()", "0.4 s"), ("testTheSidebarListsEveryWorkflow()", "1.2 s"),
        ("testALaunchedBuildAppearsInTheList()", "0.8 s"), ("testTheCycleResetsOnTheChosenDay()", "0.3 s"),
    ].enumerated().map { index, row in
        TestRow(id: "placeholder-\(index)", name: row.0, status: .success, duration: row.1, message: nil, location: nil, path: nil, line: nil, devices: [])
    }
}

nonisolated struct TestGroup: Identifiable, Equatable, Sendable {
    let className: String
    let rows: [TestRow]

    var id: String { className }
    var passedCount: Int { rows.filter { $0.status == .success }.count }
    var failedCount: Int { rows.filter { $0.status.isFailure }.count }
    var passedFraction: Double { rows.isEmpty ? 0 : Double(passedCount) / Double(rows.count) }
}

/// The Tests tab: results grouped by class, narrowed by action, status and destination.
nonisolated struct TestsTabModel: Equatable, Sendable {
    struct ActionChoice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    let groups: [TestGroup]
    let actionChoices: [ActionChoice]
    let destinations: [String]
    let total: Int
    let failed: Int

    init(
        results: [String: [CITestResult]], actions: [CIBuildAction], actionID: String? = nil,
        status: TestStatusFilter = .all, destination: String? = nil
    ) {
        let testActions = actions.filter { results[$0.id] != nil }
        actionChoices = testActions.map { ActionChoice(id: $0.id, name: $0.name ?? "?") }

        let scoped = testActions.filter { actionID == nil || $0.id == actionID }.flatMap { results[$0.id] ?? [] }
        destinations = Set(scoped.flatMap { $0.devices.map(\.deviceName) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let narrowed = scoped.filter { result in
            status.includes(result.status)
                && (destination == nil || result.devices.contains { $0.deviceName == destination })
        }
        total = narrowed.count
        failed = narrowed.filter { $0.status.isFailure }.count

        let byClass = Dictionary(grouping: narrowed) { $0.className?.nilIfBlank ?? String(localized: "Other tests") }
        groups = byClass
            .map { className, results in
                TestGroup(
                    className: className,
                    rows: results
                        .sorted { ($0.name ?? "") < ($1.name ?? "") }
                        .map { Self.row($0, destination: destination) }
                )
            }
            .sorted { lhs, rhs in
                // Groups with failures come first: that is what is being looked for.
                if (lhs.failedCount > 0) != (rhs.failedCount > 0) { return lhs.failedCount > 0 }
                return lhs.className.localizedStandardCompare(rhs.className) == .orderedAscending
            }
    }

    static func row(_ result: CITestResult, destination: String?) -> TestRow {
        let devices = destination.map { name in result.devices.filter { $0.deviceName == name } } ?? result.devices
        return TestRow(
            id: result.id, name: result.name ?? "?", status: result.status,
            duration: result.duration.map { Duration.seconds($0).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)) },
            message: result.message?.nilIfBlank,
            location: result.file.flatMap(Self.location(of:)), path: result.file?.path, line: result.file?.lineNumber, devices: devices
        )
    }

    static func location(of file: CIFileLocation) -> String? {
        guard let path = file.path?.nilIfBlank else { return nil }
        let name = (path as NSString).lastPathComponent
        return file.lineNumber.map { "\(name):\($0)" } ?? name
    }
}

nonisolated struct IssueRow: Identifiable, Equatable, Sendable {
    let id: String
    let type: CIIssueType
    let message: String
    let category: String?
    let location: String?
    let path: String?
    let line: Int?
}

nonisolated struct IssueGroup: Identifiable, Equatable, Sendable {
    let actionID: String
    let actionName: String
    let rows: [IssueRow]

    var id: String { actionID }

    /// The rows of the Issues tab's skeleton, with a card around them.
    static let placeholder = IssueGroup(actionID: "placeholder", actionName: "Archive", rows: [
        ("The value of type ‘Settings’ has no member ‘resetDay’", "Compiler"),
        ("Variable ‘cycle’ was never mutated; consider changing to ‘let’", "Compiler"),
        ("Cannot find ‘WorkflowRow’ in scope", "Compiler"),
        ("No signing certificate was found for the archive", "Signing"),
    ].enumerated().map { index, row in
        IssueRow(id: "placeholder-\(index)", type: index.isMultiple(of: 2) ? .error : .warning, message: row.0, category: row.1, location: nil, path: nil, line: nil)
    })
}

nonisolated extension CIIssueType {
    var label: String {
        switch self {
        case .error: String(localized: "Error")
        case .testFailure: String(localized: "Test failure")
        case .warning: String(localized: "Warning")
        case .analyzerWarning: String(localized: "Analyzer warning")
        case .unknown(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .error, .testFailure: "xmark.octagon.fill"
        case .warning, .analyzerWarning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var severity: Int {
        switch self {
        case .error: 0
        case .testFailure: 1
        case .warning: 2
        case .analyzerWarning: 3
        case .unknown: 4
        }
    }
}

/// The Issues tab: errors, test failures, warnings and analyzer findings, by action.
nonisolated struct IssuesTabModel: Equatable, Sendable {
    let groups: [IssueGroup]
    var total: Int { groups.reduce(0) { $0 + $1.rows.count } }

    init(issues: [String: [CIIssue]], actions: [CIBuildAction]) {
        groups = actions.compactMap { action in
            guard let found = issues[action.id], !found.isEmpty else { return nil }
            let rows = found
                .sorted { ($0.type.severity, $0.message ?? "") < ($1.type.severity, $1.message ?? "") }
                .map { issue in
                    IssueRow(
                        id: issue.id, type: issue.type, message: issue.message?.nilIfBlank ?? issue.type.label,
                        category: issue.category?.nilIfBlank, location: issue.file.flatMap(TestsTabModel.location(of:)),
                        path: issue.file?.path, line: issue.file?.lineNumber
                    )
                }
            return IssueGroup(actionID: action.id, actionName: action.name ?? "?", rows: rows)
        }
    }
}
