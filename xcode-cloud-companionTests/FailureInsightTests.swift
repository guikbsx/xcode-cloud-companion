import Foundation
import Testing
@testable import XcodeCloudCompanion

private let day = Date(timeIntervalSince1970: 1_791_547_200)
private let repo = "/Volumes/workspace/repository/"

private func run(status: CICompletionStatus? = .failed) -> CIBuildRun {
    CIBuildRun(
        id: "run-412", productID: "p1", number: 412, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(372),
        executionProgress: .complete, completionStatus: status, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Release",
        sourceBranchOrTag: "main"
    )
}

private func action(_ id: String, _ name: String, type: CIActionType) -> CIBuildAction {
    CIBuildAction(
        id: id, buildRunID: "run-412", name: name, actionType: type, startedDate: day, finishedDate: day, executionProgress: .complete,
        completionStatus: .failed, isRequiredToPass: true, issueCounts: nil
    )
}

private func issue(
    _ id: String, _ message: String, path: String? = repo + "Sources/Cart.swift", line: Int? = 42, type: CIIssueType = .error, category: String? = nil
) -> CIIssue {
    CIIssue(id: id, buildActionID: "build", type: type, message: message, category: category, file: path.map { CIFileLocation(path: $0, lineNumber: line) })
}

private func failing(_ name: String, status: CITestStatus = .failure, message: String? = "XCTAssertEqual failed") -> CITestResult {
    CITestResult(
        id: "test-\(name)", buildActionID: "test", className: "CartTests", name: name, status: status, message: message,
        file: CIFileLocation(path: repo + "Tests/CartTests.swift", lineNumber: 12),
        devices: [CITestDeviceResult(deviceName: "iPhone 17", osVersion: "26.0", status: .failure, duration: 1)]
    )
}

private func prompt(
    issues: [CIIssue] = [], tests: [CITestResult] = [], issuesComplete: Bool = true, testsComplete: Bool = true, status: CICompletionStatus? = .failed
) -> BuildFailurePrompt {
    BuildFailurePrompt(
        run: run(status: status), product: CIProduct(id: "p1", name: "cart", productType: "APP", appID: "1", appName: "Cart", bundleID: nil),
        workflow: CIWorkflow(id: "wf", name: "Release", testDestinationCounts: [1], xcodeVersionName: "Xcode 27.1"),
        actions: [action("build", "Build - iOS", type: .build), action("test", "Test - iOS", type: .test)],
        extras: BuildExtras(
            issuesByAction: Dictionary(grouping: issues, by: \.buildActionID), testsByAction: Dictionary(grouping: tests, by: \.buildActionID),
            issuesComplete: issuesComplete, testsComplete: testsComplete
        ),
        reference: nil
    )
}

private func input(issues: [CIIssue] = [], tests: [CITestResult] = [], budget: Int = FailureInsightInput.characterBudget) -> FailureInsightInput {
    FailureInsightInput(prompt: prompt(issues: issues, tests: tests), characterBudget: budget)!
}

private func manyTests(_ count: Int, message: String = "XCTAssertEqual failed") -> [CITestResult] {
    (0..<count).map { failing("testCase\($0)", message: message) }
}

struct FailureCategoryTests {
    @Test func nothingIsDecidedWhileIssuesOrTestsAreNotLoaded() {
        #expect(FailureCategory(prompt: prompt(issuesComplete: false)) == nil)
        #expect(FailureCategory(prompt: prompt(testsComplete: false)) == nil)
    }

    @Test func anErrorInASourceFileIsACompileFailureEvenWithFailedTests() {
        #expect(FailureCategory(prompt: prompt(issues: [issue("e1", "Cannot find 'total' in scope")])) == .compilation)
        #expect(FailureCategory(prompt: prompt(issues: [issue("e1", "Cannot find 'total' in scope")], tests: [failing("testA")])) == .compilation)
    }

    @Test func anErrorWithoutAFileIsAConfigurationProblem() {
        let missingScheme = issue("e1", "The scheme Cart does not exist", path: nil, line: nil)
        let emptyPath = issue("e2", "Unsupported destination", path: "  ", line: nil)

        #expect(FailureCategory(prompt: prompt(issues: [missingScheme])) == .configuration)
        #expect(FailureCategory(prompt: prompt(issues: [emptyPath])) == .configuration)
    }

    @Test func theCompilerStepIsACompileFailureEvenWithoutAFile() {
        let linker = issue("e1", "Undefined symbols for architecture arm64", path: nil, line: nil, category: "Xcodebuild")

        #expect(FailureCategory(prompt: prompt(issues: [linker])) == .compilation)
    }

    @Test func aFailedDistributionStepIsADistributionFailure() {
        let export = issue("e1", "Exporting for App Store Distribution failed.", path: nil, line: nil, category: "ExportArchiveStep")
        let prepare = issue("e2", "Preparing build for App Store Connect failed", path: nil, line: nil, category: "PrepareBuildForAppStoreConnect")
        let scheme = issue("e3", "A scheme called Cart does not exist", path: nil, line: nil, category: "ResolvePackageDependenciesStep")

        #expect(FailureCategory(prompt: prompt(issues: [export])) == .distribution)
        #expect(FailureCategory(prompt: prompt(issues: [export, prepare])) == .distribution)
        #expect(FailureCategory(prompt: prompt(issues: [export, scheme])) == .configuration)
    }

    @Test func signingMessagesWinOverEverythingElse() {
        let messages = [
            "No profiles for 'com.example.cart' were found", "Provisioning profile \"Cart\" doesn't include signing certificate",
            "Code signing is required for product type 'Application'", "Signing for \"Cart\" requires a development team.",
        ]
        for message in messages {
            #expect(FailureCategory(prompt: prompt(issues: [issue("e1", message)], tests: [failing("testA")])) == .signing)
        }
    }

    @Test func failedTestsAreFlakyOnlyWhenEveryOneOfThemIsMixed() {
        let mixed = [failing("testA", status: .mixed), failing("testB", status: .mixed)]

        #expect(FailureCategory(prompt: prompt(tests: mixed)) == .flakyTest)
        #expect(FailureCategory(prompt: prompt(tests: mixed + [failing("testC")])) == .tests)
        #expect(FailureCategory(prompt: prompt(tests: [failing("testC")])) == .tests)
    }

    @Test func aBuildThatErroredWithNothingToShowIsInfrastructureAndAFailedOneIsOther() {
        #expect(FailureCategory(prompt: prompt(status: .errored)) == .infrastructure)
        #expect(FailureCategory(prompt: prompt(status: .failed)) == .other)
    }

    @Test func aWarningAloneLeavesTheCauseOpen() {
        let warning = issue("w1", "Unused variable", type: .warning)

        #expect(FailureCategory(prompt: prompt(issues: [warning])) == .other)
    }
}

struct FailureInsightInputTests {
    @Test func noInputWhileTheCategoryIsUnknown() {
        #expect(FailureInsightInput(prompt: prompt(testsComplete: false)) == nil)
    }

    @Test func factsComeFirstAndSayThatNoTestFailed() {
        let value = input(issues: [issue("e1", "Cannot find 'total' in scope"), issue("e2", "Value of type 'Cart' has no member 'sum'", line: 7)])

        #expect(value.text.hasPrefix("""
        ## Facts
        - Failure category, decided by rules: compilation
        - Build: failed
        - Errors: 2
        - Failed tests: 0 (no test failed)

        ## Actions
        """))
        #expect(value.errorCount == 2)
        #expect(value.failedTestCount == 0)
        #expect(value.text.contains("## Errors (2)\n- Sources/Cart.swift:42\n   Cannot find 'total' in scope"))
        #expect(!value.text.contains("## Failed tests"))
    }

    @Test func failedTestsAreNumberedFromZeroAndMixedOnesAreCounted() {
        let value = input(tests: [failing("testA"), failing("testB", status: .mixed), failing("testC")])

        #expect(value.category == .tests)
        #expect(value.text.contains("- Failed tests: 3 (1 with mixed results: passed and failed)"))
        #expect(value.text.contains("## Failed tests (3)\n[0] CartTests/testA\n"))
        #expect(value.text.contains("[1] CartTests/testB (MIXED, likely flaky)"))
        #expect(value.text.contains("[2] CartTests/testC"))
        #expect(value.shownTestCount == 3)
    }

    @Test func theTextIsCutToTheBudgetAtAnEntryBoundary() {
        let long = String(repeating: "expected value differs ", count: 20)
        let value = input(tests: manyTests(300, message: long))

        #expect(value.text.count <= FailureInsightInput.characterBudget)
        #expect(value.failedTestCount == 300)
        #expect(value.shownTestCount > 0 && value.shownTestCount < 300)
        #expect(value.text.contains("[\(value.shownTestCount - 1)] "))
        #expect(!value.text.contains("[\(value.shownTestCount)] "))
        #expect(value.text.hasSuffix("and \(300 - value.shownTestCount) more"))
    }

    @Test func manyFailedTestsAreToldByNameAndShortenedMessageSoThatMoreOfThemFit() {
        let message = String(repeating: "keyNotFound ", count: 30)
        let value = input(tests: manyTests(40, message: message))

        #expect(value.shownTestCount == 40)
        #expect(!value.text.contains("Fails on:"))
        #expect(!value.text.contains("Tests/CartTests.swift"))
        #expect(value.text.count <= FailureInsightInput.characterBudget)
        #expect(input(tests: manyTests(12, message: message)).text.contains("Fails on: iPhone 17 (OS 26.0)"))
    }

    @Test func errorsAndTestsShareTheRoomWhenBothAreLong() {
        let long = String(repeating: "x", count: 280)
        let errors = (0..<60).map { issue("e\($0)", long, line: $0 + 1) }
        let value = input(issues: errors, tests: manyTests(60, message: long))

        #expect(value.text.count <= FailureInsightInput.characterBudget)
        #expect(value.text.contains("## Errors (60)"))
        #expect(value.shownTestCount > 0)
    }

    @Test func aTinyBudgetStillKeepsTheBudgetAndOneEntry() {
        let value = input(issues: [issue("e1", String(repeating: "boom ", count: 100))], budget: 420)

        #expect(value.text.count <= 420)
        #expect(value.text.contains("## Errors (1)"))
    }

    @Test func messagesAreCutShorterThanInTheClipboardPrompt() {
        let value = input(issues: [issue("e1", String(repeating: "a", count: 500))])

        #expect(value.text.contains(String(repeating: "a", count: FailureInsightInput.messageLimit) + "…"))
        #expect(!value.text.contains(String(repeating: "a", count: FailureInsightInput.messageLimit + 1)))
    }
}

struct FailureInsightValidatorTests {
    private let sample = input(issues: [issue("e1", "Cannot find 'total' in scope")], tests: manyTests(8))

    private func problems(_ headline: String) -> [FailureInsightValidator.HeadlineProblem] {
        FailureInsightValidator.problems(inHeadline: headline, input: sample)
    }

    @Test func aShortFaithfulSentenceIsAccepted() {
        #expect(problems("Cart.swift ne compile pas : 1 erreur.").isEmpty)
        #expect(problems("8 tests de CartTests échouent").isEmpty)
        #expect(problems("Xcode 27 est configuré sur ce workflow").isEmpty == false)
    }

    @Test func anEmptyHeadlineIsRejected() {
        #expect(problems("  ") == [.empty])
    }

    @Test func aHeadlineOverNinetyCharactersIsRejected() {
        let long = String(repeating: "a", count: 91)

        #expect(problems(long) == [.tooLong(91)])
        #expect(problems(String(repeating: "a", count: 90)).isEmpty)
    }

    @Test func twoSentencesOrTwoLinesAreRejected() {
        #expect(problems("La compilation échoue. Les tests aussi.") == [.notOneSentence])
        #expect(problems("La compilation échoue\nles tests aussi") == [.notOneSentence])
        #expect(problems("Est-ce que Cart.swift compile ?").isEmpty)
    }

    @Test func aFileNameThatIsNotInTheDataIsRejected() {
        #expect(problems("Erreur dans Checkout.swift") == [.unknownFileName("Checkout.swift")])
        #expect(problems("Erreur dans Sources/Cart.swift").isEmpty)
    }

    @Test func aNumberThatIsNotInTheDataIsRejected() {
        #expect(problems("37 tests échouent") == [.unknownNumber("37")])
        #expect(problems("1 erreur et 8 tests").isEmpty)
    }

    @Test func theHeadlineIsTidiedBeforeItIsShown() {
        #expect(FailureInsightValidator.normalized("  un test a dépassé le temps.\n") == "Un test a dépassé le temps")
        #expect(FailureInsightValidator.normalized("Déjà propre") == "Déjà propre")
        #expect(FailureInsightValidator.normalized(" ") == "")
    }

    @Test func groupsAreCleanedOfIndexesOutOfRangeOrAlreadyTaken() {
        let first = FailureInsight.Group(title: "Totaux du panier", testIndexes: [0, 1, 2])
        let second = FailureInsight.Group(title: "Arrondis", testIndexes: [4, 5])

        #expect(FailureInsightValidator.validGroups([first, second], input: sample) == [first, second])
        #expect(FailureInsightValidator.validGroups([first, second, .init(title: "Hors champ", testIndexes: [8, -1])], input: sample) == [first, second])
        #expect(FailureInsightValidator.validGroups([first, .init(title: "Doublon", testIndexes: [2, 3, 3, 99])], input: sample)
            == [first, .init(title: "Doublon", testIndexes: [3])])
        #expect(FailureInsightValidator.validGroups([first, .init(title: "Tout pris", testIndexes: [0, 1])], input: sample) == nil)
    }

    @Test func groupTitlesAreShortAndNotEmpty() {
        let ok = FailureInsight.Group(title: "Totaux", testIndexes: [0, 1])
        let other = FailureInsight.Group(title: "Arrondis", testIndexes: [2, 3])
        let exact = FailureInsight.Group(title: String(repeating: "t", count: 60), testIndexes: [4])

        #expect(FailureInsightValidator.validGroups([ok, .init(title: String(repeating: "t", count: 61), testIndexes: [4])], input: sample) == nil)
        #expect(FailureInsightValidator.validGroups([ok, .init(title: " ", testIndexes: [4])], input: sample) == nil)
        #expect(FailureInsightValidator.validGroups([ok, other, .init(title: String(repeating: "t", count: 61), testIndexes: [4])], input: sample) == [ok, other])
        #expect(FailureInsightValidator.validGroups([ok, exact, other], input: sample)?.count == 3)
    }

    @Test func oneGroupIsNoGroupAndEmptyGroupsDoNotCount() {
        let ok = FailureInsight.Group(title: "Totaux", testIndexes: [0, 1])

        #expect(FailureInsightValidator.validGroups([ok], input: sample) == nil)
        #expect(FailureInsightValidator.validGroups([ok, .init(title: "Vide", testIndexes: [])], input: sample) == nil)
        #expect(FailureInsightValidator.validGroups([], input: sample) == nil)
    }

    @Test func testsLeftOutOfGroupsAreFine() {
        let groups = [FailureInsight.Group(title: "A", testIndexes: [0]), FailureInsight.Group(title: "B", testIndexes: [7])]

        #expect(FailureInsightValidator.validGroups(groups, input: sample) == groups)
    }
}

struct FailureInsightPromptsTests {
    @Test func theCategoryIsGivenAsAFactInBothLanguages() {
        let value = input(issues: [issue("e1", "The scheme Cart does not exist", path: nil, line: nil)])

        #expect(FailureInsightPrompts.instructions(for: value, language: .english, attempt: .first).contains("configuration, the Xcode Cloud workflow"))
        #expect(FailureInsightPrompts.instructions(for: value, language: .french, attempt: .first).contains("configuration, le workflow Xcode Cloud"))
    }

    @Test func groupsAreAskedOnlyForSixShownTestsOrMore() {
        let few = input(tests: manyTests(5))
        let many = input(tests: manyTests(6))

        #expect(!FailureInsightPrompts.instructions(for: few, language: .english, attempt: .first).contains("Groups:"))
        #expect(FailureInsightPrompts.instructions(for: many, language: .english, attempt: .first).contains("Groups:"))
        #expect(FailureInsightPrompts.instructions(for: many, language: .french, attempt: .first).contains("Groupes :"))
    }

    @Test func theFirmerInstructionOnlyAddsToTheFirstOne() {
        let value = input(tests: manyTests(2))
        let retry = FailureInsightAttempt.retry(rejected: "x", problems: [.tooLong(104)])
        let first = FailureInsightPrompts.instructions(for: value, language: .french, attempt: .first)
        let second = FailureInsightPrompts.instructions(for: value, language: .french, attempt: retry)

        #expect(second.hasPrefix(first))
        #expect(second.contains("70 caractères"))
    }

    @Test func aRetryTellsTheModelWhatWasWrongWithItsHeadline() {
        let value = input(tests: manyTests(2))
        let problems: [FailureInsightValidator.HeadlineProblem] = [.tooLong(104), .unknownFileName("Foo.swift"), .unknownNumber("37"), .notOneSentence]
        let retry = FailureInsightAttempt.retry(rejected: "Trop long", problems: problems)
        let english = FailureInsightPrompts.request(for: value, language: .english, attempt: retry)
        let french = FailureInsightPrompts.request(for: value, language: .french, attempt: retry)

        #expect(english.contains("Previous headline, rejected: \"Trop long\""))
        #expect(english.contains("it had 104 characters, the limit is 90; it named Foo.swift, which is not in the data; it contained the number 37, which is not in the data; it had several sentences"))
        #expect(french.contains("Titre précédent, refusé : « Trop long »"))
        #expect(french.contains("il faisait 104 caractères, la limite est 90"))
        #expect(FailureInsightPrompts.request(for: value, language: .french, attempt: .first).hasSuffix(value.text))
    }

    @Test func theLanguageFollowsTheLocale() {
        #expect(FailureInsightLanguage(locale: Locale(identifier: "fr_CA")) == .french)
        #expect(FailureInsightLanguage(locale: Locale(identifier: "de_DE")) == .english)
    }
}

private actor ScriptedGenerator: FailureInsightGenerating {
    enum Step {
        case answer(RawFailureInsight)
        case fail
    }

    private var steps: [Step]
    private(set) var attempts: [FailureInsightAttempt] = []
    private(set) var running = 0
    private(set) var peak = 0
    private let delay: Duration

    init(_ steps: [Step], delay: Duration = .zero) {
        self.steps = steps
        self.delay = delay
    }

    func generate(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) async throws -> RawFailureInsight {
        running += 1
        peak = max(peak, running)
        defer { running -= 1 }
        attempts.append(attempt)
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !steps.isEmpty else { throw FailureInsightError.unavailable("script ended") }
        switch steps.removeFirst() {
        case .answer(let raw): return raw
        case .fail: throw FailureInsightError.unavailable("scripted")
        }
    }
}

private func answer(_ headline: String, groups: [FailureInsight.Group] = []) -> ScriptedGenerator.Step {
    .answer(RawFailureInsight(headline: headline, groups: groups))
}

struct FailureInsightServiceTests {
    private let compile = input(issues: [issue("e1", "Cannot find 'total' in scope")])
    private let manyFailures = input(tests: manyTests(8))
    private let twoGroups = [
        FailureInsight.Group(title: "Totaux", testIndexes: [0, 1, 2]), FailureInsight.Group(title: "Arrondis", testIndexes: [3, 4]),
    ]

    @Test func aValidFirstAnswerIsKeptWithTheRuleCategory() async {
        let generator = ScriptedGenerator([answer("  Cart.swift ne compile pas.  ")])
        let outcome = await FailureInsightService(generator: generator).insight(for: compile, language: .french)

        #expect(outcome == .init(insight: FailureInsight(category: .compilation, headline: "Cart.swift ne compile pas", groups: nil), attempts: 1, gaveUp: false))
        #expect(await generator.attempts == [.first])
    }

    @Test func aRejectedHeadlineIsRetriedOnceWithTheFirmerInstruction() async {
        let generator = ScriptedGenerator([answer(String(repeating: "a", count: 120)), answer("Cart.swift ne compile pas")])
        let outcome = await FailureInsightService(generator: generator).insight(for: compile, language: .french)

        #expect(outcome.insight?.headline == "Cart.swift ne compile pas")
        #expect(outcome.attempts == 2)
        #expect(!outcome.gaveUp)
        #expect(await generator.attempts == [.first, .retry(rejected: String(repeating: "a", count: 120), problems: [.tooLong(120)])])
    }

    @Test func twoRejectedHeadlinesAreGivenUpWithNothingToShow() async {
        let generator = ScriptedGenerator([answer("Erreur dans Checkout.swift"), answer("37 erreurs")])
        let outcome = await FailureInsightService(generator: generator).insight(for: compile, language: .french)

        #expect(outcome == .init(insight: nil, attempts: 2, gaveUp: true))
        #expect(await generator.attempts == [.first, .retry(rejected: "Erreur dans Checkout.swift", problems: [.unknownFileName("Checkout.swift")])])
    }

    @Test func validGroupsSurviveAGivenUpHeadline() async {
        let generator = ScriptedGenerator([answer("37 erreurs", groups: twoGroups), answer("Deux phrases. Ici.", groups: twoGroups)])
        let outcome = await FailureInsightService(generator: generator).insight(for: manyFailures, language: .english)

        #expect(outcome.gaveUp)
        #expect(outcome.insight == FailureInsight(category: .tests, headline: nil, groups: twoGroups))
    }

    @Test func badGroupsAreDroppedWithoutRetryingAGoodHeadline() async {
        let bad = [FailureInsight.Group(title: "Hors champ", testIndexes: [99]), twoGroups[1]]
        let generator = ScriptedGenerator([answer("8 tests de CartTests échouent", groups: bad)])
        let outcome = await FailureInsightService(generator: generator).insight(for: manyFailures, language: .french)

        #expect(outcome.insight == FailureInsight(category: .tests, headline: "8 tests de CartTests échouent", groups: nil))
        #expect(outcome.attempts == 1)
    }

    @Test func groupsAreIgnoredWhenTheBuildHasFewFailedTests() async {
        let few = input(tests: manyTests(3))
        let generator = ScriptedGenerator([answer("3 tests de CartTests échouent", groups: twoGroups)])
        let outcome = await FailureInsightService(generator: generator).insight(for: few, language: .french)

        #expect(outcome.insight?.groups == nil)
    }

    @Test func aThrownErrorIsNoInsightAndIsNotRetried() async {
        let generator = ScriptedGenerator([.fail, answer("Cart.swift ne compile pas")])
        let outcome = await FailureInsightService(generator: generator).insight(for: compile, language: .french)

        #expect(outcome == .init(insight: nil, attempts: 1, gaveUp: false))
        #expect(await generator.attempts == [.first])
    }

    @Test func requestsRunOneAtATime() async {
        let generator = ScriptedGenerator(Array(repeating: answer("Cart.swift ne compile pas"), count: 4), delay: .milliseconds(30))
        let service = FailureInsightService(generator: generator)
        let compile = compile

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = await service.insight(for: compile, language: .french) } }
        }

        #expect(await generator.peak == 1)
        #expect(await generator.attempts.count == 4)
    }
}
