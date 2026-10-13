import Foundation
import FoundationModels
import OSLog

/// The model's answer before anything checks it.
nonisolated struct RawFailureInsight: Sendable, Equatable {
    var headline: String
    var groups: [FailureInsight.Group]
}

nonisolated enum FailureInsightError: Error, Sendable, Equatable {
    case unavailable(String)
}

nonisolated protocol FailureInsightGenerating: Sendable {
    func generate(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) async throws -> RawFailureInsight
}

@Generable
nonisolated struct ModelHeadline {
    @Guide(description: "One sentence saying what broke")
    var headline: String
}

@Generable
nonisolated struct ModelGroup {
    @Guide(description: "Short title naming what the tests have in common")
    var title: String
    @Guide(description: "The [n] indexes of the failed tests in this group")
    var testIndexes: [Int]
}

@Generable
nonisolated struct ModelHeadlineAndGroups {
    @Guide(description: "One sentence saying what broke")
    var headline: String
    @Guide(description: "Failed tests that share a cause; each failed test is in at most one group")
    var groups: [ModelGroup]
}

/// The on-device model, with a fresh session for every request: nothing from one build leaks into the next.
nonisolated struct FoundationModelsInsightGenerator: FailureInsightGenerating {
    static let headlineTokens = 200
    static let groupsTokens = 900

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func generate(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) async throws -> RawFailureInsight {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FailureInsightError.unavailable(String(describing: model.availability))
        }
        guard model.supportsLocale(language.locale) else { throw FailureInsightError.unavailable("language not supported") }

        let wantsGroups = FailureInsightPrompts.wantsGroups(input)
        let session = LanguageModelSession(instructions: FailureInsightPrompts.instructions(for: input, language: language, attempt: attempt))
        let request = FailureInsightPrompts.request(for: input, language: language, attempt: attempt)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: wantsGroups ? Self.groupsTokens : Self.headlineTokens)
        if wantsGroups {
            let answer = try await session.respond(to: request, generating: ModelHeadlineAndGroups.self, options: options).content
            return RawFailureInsight(
                headline: answer.headline,
                groups: answer.groups.map { FailureInsight.Group(title: $0.title, testIndexes: $0.testIndexes) }
            )
        }
        let answer = try await session.respond(to: request, generating: ModelHeadline.self, options: options).content
        return RawFailureInsight(headline: answer.headline, groups: [])
    }
}

/// Turns a build into a checked insight, one build at a time. Anything that goes wrong is "no insight", with the reason in the log.
actor FailureInsightService {
    struct Outcome: Sendable, Equatable {
        var insight: FailureInsight?
        var attempts: Int
        var gaveUp: Bool
    }

    private static let logger = Logger(subsystem: "com.guik.xcode-cloud-companion", category: "insight")

    private let generator: any FailureInsightGenerating
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(generator: any FailureInsightGenerating = FoundationModelsInsightGenerator()) {
        self.generator = generator
    }

    func insight(for input: FailureInsightInput, language: FailureInsightLanguage) async -> Outcome {
        await acquire()
        defer { release() }
        return await compose(input, language: language)
    }

    private func compose(_ input: FailureInsightInput, language: FailureInsightLanguage) async -> Outcome {
        var lastGroups: [FailureInsight.Group] = []
        var attempt = FailureInsightAttempt.first
        for number in 1...2 {
            let raw: RawFailureInsight
            do {
                raw = try await generator.generate(for: input, language: language, attempt: attempt)
            } catch {
                Self.logger.info("No insight: \(Self.reason(error), privacy: .public)")
                return Outcome(insight: nil, attempts: number, gaveUp: false)
            }
            lastGroups = FailureInsightPrompts.wantsGroups(input) ? raw.groups : []
            let problems = FailureInsightValidator.problems(inHeadline: raw.headline, input: input)
            if problems.isEmpty {
                let insight = FailureInsight(
                    category: input.category, headline: FailureInsightValidator.normalized(raw.headline),
                    groups: FailureInsightValidator.validGroups(lastGroups, input: input)
                )
                return Outcome(insight: insight, attempts: number, gaveUp: false)
            }
            Self.logger.info("Headline rejected on attempt \(number): \(problems.count) problem(s)")
            attempt = .retry(rejected: raw.headline, problems: problems)
        }
        let groups = FailureInsightValidator.validGroups(lastGroups, input: input)
        let insight = groups.map { FailureInsight(category: input.category, headline: nil, groups: $0) }
        return Outcome(insight: insight, attempts: 2, gaveUp: true)
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private static func reason(_ error: any Error) -> String {
        if case .unavailable(let reason)? = error as? FailureInsightError { return reason }
        let description = String(describing: error)
        return String(description.split(separator: "(").first ?? "error")
    }
}
