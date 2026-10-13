import Foundation

/// What is kept of an insight: the groups name their tests, not their positions in a list that can change.
nonisolated struct FailureInsightRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    struct TestIdentity: Codable, Sendable, Hashable {
        var action: String
        var className: String
        var name: String

        init(action: String, className: String, name: String) {
            self.action = action
            self.className = className
            self.name = name
        }

        init(_ result: CITestResult) {
            self.init(action: result.buildActionID, className: result.className ?? "", name: result.name ?? "")
        }
    }

    struct Group: Codable, Sendable, Equatable {
        var title: String
        var tests: [TestIdentity]
    }

    var schemaVersion: Int? = FailureInsightRecord.currentVersion
    var category: FailureCategory
    /// Nil when the model gave nothing usable: the category alone is kept, so it is not asked again.
    var headline: String?
    var groups: [Group]?

    init(category: FailureCategory, headline: String? = nil, groups: [Group]? = nil) {
        self.category = category
        self.headline = headline
        self.groups = groups
    }

    /// `failedTests` is the list that was sent to the model, in the same order: its positions are read once, here.
    init(category: FailureCategory, insight: FailureInsight?, failedTests: [CITestResult]) {
        let groups = insight?.groups?.compactMap { group -> Group? in
            let tests = group.testIndexes.filter(failedTests.indices.contains).map { TestIdentity(failedTests[$0]) }
            return tests.isEmpty ? nil : Group(title: group.title, tests: tests)
        }
        self.init(category: category, headline: insight?.headline, groups: (groups?.count ?? 0) >= FailureInsightValidator.minimumGroupCount ? groups : nil)
    }

    var hasGroups: Bool { groups?.isEmpty == false }

    /// Stands in for the record in the card's skeleton: the length of a typical summary, never shown as text.
    static let placeholder = FailureInsightRecord(
        category: .tests,
        headline: "Three settings tests fail because a saved value is read back before it is written."
    )
}

nonisolated struct FailureInsightCache: Sendable {
    var directory: URL

    private func fileURL(runID: String, language: FailureInsightLanguage) -> URL {
        directory.appending(path: "\(runID)-\(language.cacheKey).json")
    }

    @concurrent func load(runID: String, language: FailureInsightLanguage) async -> FailureInsightRecord? {
        guard Self.isSafe(runID), let data = try? Data(contentsOf: fileURL(runID: runID, language: language)),
              let record = try? JSONDecoder().decode(FailureInsightRecord.self, from: data),
              record.schemaVersion == FailureInsightRecord.currentVersion
        else { return nil }
        return record
    }

    @concurrent func save(_ record: FailureInsightRecord, runID: String, language: FailureInsightLanguage) async {
        guard Self.isSafe(runID) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: fileURL(runID: runID, language: language), options: [.atomic])
    }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isSafe(_ runID: String) -> Bool {
        !runID.isEmpty && runID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
