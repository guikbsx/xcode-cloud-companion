import Foundation

/// What a failed build broke, measured against the last build of its workflow that succeeded.
nonisolated struct RegressionReport: Equatable, Sendable {
    struct TestEntry: Identifiable, Equatable, Sendable {
        let id: String
        let className: String?
        let name: String
        let actionName: String
        let message: String?
        let location: String?
    }

    struct IssueEntry: Identifiable, Equatable, Sendable {
        let id: String
        let type: CIIssueType
        let message: String
        let actionName: String
        let location: String?
    }

    /// Passed in the reference, fail here: what this build broke.
    var brokenTests: [TestEntry] = []
    /// Failed in the reference too.
    var persistingTests: [TestEntry] = []
    /// Fail here and did not exist in the reference: new tests, not broken ones.
    var newFailingTests: [TestEntry] = []
    /// Errors and warnings the reference did not have.
    var newIssues: [IssueEntry] = []

    var isEmpty: Bool {
        brokenTests.isEmpty && persistingTests.isEmpty && newFailingTests.isEmpty && newIssues.isEmpty
    }

    /// The last build of the same workflow that succeeded before `run`, on the same branch when there is one.
    static func reference(for run: CIBuildRun, in snapshot: BuildSnapshot) -> CIBuildRun? {
        guard let workflowID = run.workflowID else { return nil }
        let earlier = snapshot.runs.filter { candidate in
            candidate.id != run.id && candidate.workflowID == workflowID && candidate.productID == run.productID
                && candidate.executionProgress == .complete && candidate.completionStatus == .succeeded
                && isEarlier(candidate, than: run)
        }
        let newest: ([CIBuildRun]) -> CIBuildRun? = { runs in
            runs.max { ($0.number ?? 0, $0.createdDate ?? .distantPast) < ($1.number ?? 0, $1.createdDate ?? .distantPast) }
        }
        if let branch = run.sourceBranchOrTag, let sameBranch = newest(earlier.filter { $0.sourceBranchOrTag == branch }) {
            return sameBranch
        }
        return newest(earlier)
    }

    init() {}

    /// Tests are matched by class and name, issues by type, message and file, both within actions of the same name.
    init(
        actions: [CIBuildAction], extras: BuildExtras, referenceActions: [CIBuildAction], referenceExtras: BuildExtras
    ) {
        var referenceTests: [String: CITestStatus] = [:]
        var referenceIssues: Set<String> = []
        for action in referenceActions {
            let actionName = action.name ?? ""
            for test in referenceExtras.testsByAction[action.id] ?? [] {
                referenceTests[Self.key(of: test, actionName: actionName)] = test.status
            }
            for issue in referenceExtras.issuesByAction[action.id] ?? [] {
                referenceIssues.insert(Self.key(of: issue, actionName: actionName))
            }
        }

        var seenTests: Set<String> = []
        var seenIssues: Set<String> = []
        for action in actions {
            let actionName = action.name ?? ""
            for test in extras.testsByAction[action.id] ?? [] where test.status.isFailure {
                let key = Self.key(of: test, actionName: actionName)
                guard seenTests.insert(key).inserted else { continue }
                let entry = TestEntry(
                    id: key, className: test.className?.nilIfBlank, name: test.name ?? "?", actionName: actionName,
                    message: test.message?.nilIfBlank, location: test.file.flatMap(TestsTabModel.location(of:))
                )
                switch referenceTests[key] {
                case nil: newFailingTests.append(entry)
                case let status? where status.isFailure: persistingTests.append(entry)
                default: brokenTests.append(entry)
                }
            }
            for issue in extras.issuesByAction[action.id] ?? [] where issue.type != .testFailure {
                let key = Self.key(of: issue, actionName: actionName)
                guard !referenceIssues.contains(key), seenIssues.insert(key).inserted else { continue }
                newIssues.append(IssueEntry(
                    id: key, type: issue.type, message: issue.message?.nilIfBlank ?? issue.type.label, actionName: actionName,
                    location: issue.file.flatMap(TestsTabModel.location(of:))
                ))
            }
        }
        let byName: (TestEntry, TestEntry) -> Bool = { ($0.className ?? "", $0.name) < ($1.className ?? "", $1.name) }
        brokenTests.sort(by: byName)
        persistingTests.sort(by: byName)
        newFailingTests.sort(by: byName)
        newIssues.sort { ($0.type.severity, $0.message) < ($1.type.severity, $1.message) }
    }

    /// True when both builds have their tests and issues at hand: nothing is compared against half a list.
    static func isReady(extras: BuildExtras?, referenceExtras: BuildExtras?) -> Bool {
        [extras, referenceExtras].allSatisfy { $0?.testsComplete == true && $0?.issuesComplete == true }
    }

    private static func isEarlier(_ candidate: CIBuildRun, than run: CIBuildRun) -> Bool {
        if let lhs = candidate.number, let rhs = run.number { return lhs < rhs }
        guard let lhs = candidate.createdDate, let rhs = run.createdDate else { return false }
        return lhs < rhs
    }

    private static func key(of test: CITestResult, actionName: String) -> String {
        [actionName, test.className ?? "", test.name ?? test.id].joined(separator: "\u{1F}")
    }

    /// Line numbers move with every edit: the file is enough to tell the same warning from a new one.
    private static func key(of issue: CIIssue, actionName: String) -> String {
        [actionName, issue.type.rawValue, issue.message ?? "", issue.file?.path ?? ""].joined(separator: "\u{1F}")
    }
}

/// The commits between the reference and the failed build, only when Apple gave both.
nonisolated struct CommitRange: Equatable, Sendable {
    let from: String
    let to: String
    /// The comparison on the Git host when its address is known for sure, otherwise the failed build's commit.
    let url: URL?
    let isComparison: Bool

    init?(reference: CIBuildRun, run: CIBuildRun) {
        guard let fromSha = reference.sourceCommit?.commitSha?.nilIfBlank, let toSha = run.sourceCommit?.commitSha?.nilIfBlank,
              let from = reference.sourceCommit?.shortSha, let to = run.sourceCommit?.shortSha
        else { return nil }
        self.from = from
        self.to = to
        if let comparison = Self.gitHubComparison(commitURL: run.sourceCommit?.webURL, from: fromSha, to: toSha) {
            url = comparison
            isComparison = true
        } else {
            url = run.sourceCommit?.webURL
            isComparison = false
        }
    }

    /// `https://github.com/<owner>/<repo>/commit/<sha>` becomes `…/compare/<from>...<to>`; any other address is left alone.
    static func gitHubComparison(commitURL: URL?, from: String, to: String) -> URL? {
        guard let commitURL, commitURL.scheme == "https", commitURL.host() == "github.com", from != to else { return nil }
        let parts = commitURL.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[2] == "commit", [from, to].allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/compare/\(from)...\(to)")
    }
}
