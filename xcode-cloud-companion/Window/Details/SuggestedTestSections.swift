import Foundation

/// The failed tests of a build laid out in the groups the model suggested, then the ones it left out. A test appears once.
nonisolated struct SuggestedTestSections: Equatable, Sendable {
    /// Below this many failed tests there is nothing to group.
    static let minimumFailedTests = FailureInsightPrompts.minimumTestsForGroups
    static let previewCount = 3

    struct Section: Identifiable, Equatable, Sendable {
        let id: String
        /// Nil for the tests that belong to no group.
        let title: String?
        let rows: [TestRow]

        var isOthers: Bool { title == nil }
        var count: Int { rows.count }
        var hiddenCount: Int { max(0, rows.count - SuggestedTestSections.previewCount) }

        func visibleRows(showingAll: Bool) -> [TestRow] {
            showingAll ? rows : Array(rows.prefix(SuggestedTestSections.previewCount))
        }
    }

    let sections: [Section]

    /// Nil when there is nothing to suggest: no record, too few failed tests, or fewer than two groups whose tests are still in the build.
    init?(record: FailureInsightRecord?, failed: [CITestResult], actions: [CIBuildAction] = []) {
        let actionNames = Dictionary(actions.map { ($0.id, $0.name ?? "") }, uniquingKeysWith: { first, _ in first })
        guard failed.count >= Self.minimumFailedTests, let groups = record?.groups, !groups.isEmpty else { return nil }
        var byIdentity: [FailureInsightRecord.TestIdentity: [CITestResult]] = [:]
        for result in failed { byIdentity[FailureInsightRecord.TestIdentity(result), default: []].append(result) }

        var claimed: Set<String> = []
        var built: [Section] = []
        for (index, group) in groups.enumerated() {
            var members: [CITestResult] = []
            for identity in group.tests {
                for result in byIdentity[identity] ?? [] where claimed.insert(result.id).inserted { members.append(result) }
            }
            if !members.isEmpty { built.append(Section(id: "group-\(index)", title: group.title, rows: Self.rows(members, actionNames: actionNames))) }
        }
        guard built.count >= FailureInsightValidator.minimumGroupCount else { return nil }

        let others = failed.filter { !claimed.contains($0.id) }
        if !others.isEmpty { built.append(Section(id: "others", title: nil, rows: Self.rows(others, actionNames: actionNames))) }
        sections = built
    }

    private static func rows(_ results: [CITestResult], actionNames: [String: String]) -> [TestRow] {
        results
            .sorted {
                let order = ($0.className ?? "").localizedStandardCompare($1.className ?? "")
                return order == .orderedSame ? ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending : order == .orderedAscending
            }
            .map { TestsTabModel.row($0, destination: nil, actionName: actionNames[$0.buildActionID]) }
    }
}
