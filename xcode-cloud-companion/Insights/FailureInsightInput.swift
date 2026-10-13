import Foundation

/// The text the model reads about one failed build: facts the rules already know, then the data, cut to a budget.
nonisolated struct FailureInsightInput: Sendable, Equatable {
    /// The model's context is 8,192 tokens. The instructions, the answer format and the answer take about 1,200;
    /// at 2.5 characters per token (paths and Swift identifiers tokenize badly) 6,000 characters are about 2,400.
    static let characterBudget = 6000
    static let maximumActionLines = 12
    static let messageLimit = 300
    /// Past this many failed tests each one is told by its name and message alone, the message cut until every test fits.
    static let compactAbove = 12
    static let compactMessageLimits = [200, 140, 100, 70]

    let text: String
    let category: FailureCategory
    let errorCount: Int
    let failedTestCount: Int
    /// Failed tests that made it into the text: the model may name `[0]` to `[shownTestCount - 1]` and no other.
    let shownTestCount: Int

    init?(prompt: BuildFailurePrompt, characterBudget: Int = FailureInsightInput.characterBudget) {
        guard let category = FailureCategory(prompt: prompt) else { return nil }
        let errors = prompt.errors
        let tests = prompt.failedTests

        let facts = Self.facts(category: category, prompt: prompt, errorCount: errors.count, tests: tests)
        let actions = Self.actions(prompt.actionsSection)
        let fixed = [facts, actions].compactMap(\.self)
        let used = fixed.reduce(0) { $0 + $1.count + 2 }
        let room = max(0, characterBudget - used)

        var errorPrompt = prompt
        errorPrompt.messageLimit = Self.messageLimit
        let errorRoom = tests.isEmpty ? room : room / 2
        let shownErrors = Self.fit(
            errors.map { errorPrompt.errorEntry($0, label: "-") }, header: "## Errors (\(errors.count))", limit: errorRoom
        )

        let testRoom = max(0, room - shownErrors.length)
        var testPrompt = prompt
        testPrompt.compactTests = tests.count > Self.compactAbove
        var shownTests = (text: String?.none, shown: 0, length: 0)
        for limit in (testPrompt.compactTests ? Self.compactMessageLimits : [Self.messageLimit]) {
            testPrompt.messageLimit = limit
            shownTests = Self.fit(
                tests.enumerated().map { testPrompt.testEntry($1, label: "[\($0)]") }, header: "## Failed tests (\(tests.count))", limit: testRoom
            )
            if shownTests.shown == tests.count { break }
        }

        self.text = (fixed + [shownErrors.text, shownTests.text].compactMap(\.self)).joined(separator: "\n\n")
        self.category = category
        self.errorCount = errors.count
        self.failedTestCount = tests.count
        self.shownTestCount = shownTests.shown
    }

    private static func facts(category: FailureCategory, prompt: BuildFailurePrompt, errorCount: Int, tests: [CITestResult]) -> String {
        let status = CLIStatusWord.word(progress: prompt.run.executionProgress, completion: prompt.run.completionStatus)
        let mixed = tests.filter { $0.status == .mixed }.count
        var testLine = "- Failed tests: \(tests.count)"
        if tests.isEmpty {
            testLine += " (no test failed)"
        } else if mixed > 0 {
            testLine += " (\(mixed) with mixed results: passed and failed)"
        }
        return """
        ## Facts
        - Failure category, decided by rules: \(category.rawValue)
        - Build: \(status)
        - Errors: \(errorCount)
        \(testLine)
        """
    }

    private static func actions(_ section: String?) -> String? {
        guard let section else { return nil }
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maximumActionLines + 1 else { return section }
        return (lines.prefix(maximumActionLines + 1) + ["and \(lines.count - 1 - maximumActionLines) more"]).joined(separator: "\n")
    }

    /// Whole entries while they fit; the first one is cut rather than dropped, so a section never comes out empty.
    private static func fit(_ entries: [String], header: String, limit: Int) -> (text: String?, shown: Int, length: Int) {
        guard !entries.isEmpty, limit > header.count + 8 else { return (nil, 0, 0) }
        var lines = [header]
        var length = header.count
        var shown = 0
        for entry in entries {
            let remaining = entries.count - shown
            let reserve = remaining > 1 ? "and \(remaining - 1) more".count + 1 : 0
            if length + 1 + entry.count + reserve <= limit {
                lines.append(entry)
                length += 1 + entry.count
                shown += 1
            } else if shown == 0 {
                let reserveAfterCut = entries.count > 1 ? "and \(entries.count - 1) more".count + 1 : 0
                let cut = String(entry.prefix(max(1, limit - length - 2 - reserveAfterCut))) + "…"
                lines.append(cut)
                length += 1 + cut.count
                shown = 1
                break
            } else {
                break
            }
        }
        if shown < entries.count {
            let more = "and \(entries.count - shown) more"
            lines.append(more)
            length += 1 + more.count
        }
        return (lines.joined(separator: "\n"), shown, length + 2)
    }
}
