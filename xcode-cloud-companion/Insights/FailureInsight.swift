import Foundation

/// What the app can say about a failed build in a line: the category comes from rules, the rest from the model.
nonisolated struct FailureInsight: Codable, Sendable, Equatable {
    /// A set of failed tests that share a cause; the indexes are positions in `BuildFailurePrompt.failedTests`.
    struct Group: Codable, Sendable, Equatable {
        var title: String
        var testIndexes: [Int]
    }

    var category: FailureCategory
    var headline: String?
    var groups: [Group]?
}
