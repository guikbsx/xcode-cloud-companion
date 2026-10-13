import Foundation

/// What the model wrote is checked against the data it was given: a sentence that fails any check is not shown.
nonisolated enum FailureInsightValidator {
    static let maximumHeadlineLength = 90
    static let maximumGroupTitleLength = 60
    static let minimumGroupCount = 2

    enum HeadlineProblem: Equatable, Sendable {
        case empty
        case tooLong(Int)
        case notOneSentence
        case unknownFileName(String)
        case unknownNumber(String)
    }

    static func problems(inHeadline headline: String, input: FailureInsightInput) -> [HeadlineProblem] {
        let text = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [.empty] }
        var problems: [HeadlineProblem] = []
        if text.count > maximumHeadlineLength { problems.append(.tooLong(text.count)) }
        if !isOneSentence(text) { problems.append(.notOneSentence) }
        for name in fileNames(in: text) where !input.text.contains(name) { problems.append(.unknownFileName(name)) }
        let known = knownNumbers(in: input.text)
        for number in numbers(in: text) where !known.contains(number) { problems.append(.unknownNumber(number)) }
        return problems
    }

    /// What the interface shows: no stray spaces, a capital first letter, no full stop at the end.
    static func normalized(_ headline: String) -> String {
        var text = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The groups cleaned of what the model got wrong: a title that is empty or too long drops its group, an index out of
    /// range or already taken by an earlier group drops that index, a group left without a test is dropped. Nil when fewer
    /// than two groups remain.
    static func validGroups(_ groups: [FailureInsight.Group], input: FailureInsightInput) -> [FailureInsight.Group]? {
        var used: Set<Int> = []
        var kept: [FailureInsight.Group] = []
        for group in groups {
            let title = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maximumGroupTitleLength, !title.contains(where: \.isNewline) else { continue }
            let indexes = group.testIndexes.filter { (0..<input.shownTestCount).contains($0) && used.insert($0).inserted }
            if !indexes.isEmpty { kept.append(FailureInsight.Group(title: title, testIndexes: indexes)) }
        }
        return kept.count >= minimumGroupCount ? kept : nil
    }

    private static func isOneSentence(_ text: String) -> Bool {
        if text.contains(where: \.isNewline) { return false }
        return text.range(of: #"[.!?…]\s+\S"#, options: .regularExpression) == nil
    }

    private static func fileNames(in text: String) -> [String] {
        matches(of: #"(?<![\w.])[A-Za-z_][\w+\-]*\.[A-Za-z][A-Za-z0-9]{0,11}(?![\w])"#, in: text)
    }

    private static func numbers(in text: String) -> [String] {
        matches(of: #"\d+(?:[.,]\d+)*"#, in: text)
    }

    private static func knownNumbers(in text: String) -> Set<String> {
        var result: Set<String> = []
        for number in numbers(in: text) {
            result.insert(number)
            result.formUnion(number.split(whereSeparator: { $0 == "." || $0 == "," }).map(String.init))
        }
        return result
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        var found: [String] = []
        var start = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) {
            found.append(String(text[range]))
            start = range.upperBound
        }
        return found
    }
}
