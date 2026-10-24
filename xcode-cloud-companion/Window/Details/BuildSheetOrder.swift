import Foundation

/// The four parts of a build sheet's detail card.
nonisolated enum BuildPart: Hashable, Sendable, CaseIterable {
    case tests, problems, actions, artifacts

    var title: String {
        switch self {
        case .tests: String(localized: "Tests")
        case .problems: String(localized: "Issues")
        case .actions: String(localized: "Actions")
        case .artifacts: String(localized: "Artifacts")
        }
    }

    var systemImage: String {
        switch self {
        case .tests: "checklist"
        case .problems: "exclamationmark.triangle"
        case .actions: "gearshape"
        case .artifacts: "shippingbox"
        }
    }
}

/// Which parts of a build's detail card stand, in which order, and which are open at first. Decided from what the
/// snapshot already knows, never from a request; the card works it out once, when the sheet opens, so nothing moves while it is read.
nonisolated struct BuildSheetOrder: Equatable, Sendable {
    enum TestsPresence: Equatable, Sendable {
        /// A test action ran, or may still run.
        case present
        /// The workflow tests, but no test action started: the build stopped before.
        case notRun
        /// The workflow has no test action.
        case absent
    }

    struct Facts: Equatable, Sendable {
        /// Pending or running.
        var isRunning: Bool
        var completion: CICompletionStatus?
        /// Nil while the build's issues and test results are not read.
        var category: FailureCategory?
        var issueCounts: CIIssueCounts?
        /// The build produced an archive or reached TestFlight.
        var delivered = false
        var tests = TestsPresence.present
        var issuesKnownEmpty = false
        var artifactsKnownEmpty = false

        var isFailed: Bool {
            !isRunning && (completion == .failed || completion == .errored)
        }
    }

    /// A part that has nothing to show and so has no line: it is told at the foot of the card.
    enum Omission: Equatable, Sendable {
        case noIssues, noArtifacts, testsNotRun, noTests
    }

    let parts: [BuildPart]
    /// The parts open until the user decides otherwise.
    let expanded: Set<BuildPart>
    let omissions: [Omission]

    init(_ facts: Facts) {
        var order: [BuildPart]
        if facts.isRunning {
            order = [.actions, .tests, .problems, .artifacts]
        } else if facts.isFailed {
            switch Self.cause(of: facts) {
            case .tests: order = [.tests, .problems, .actions, .artifacts]
            case .problems: order = [.problems, .tests, .actions, .artifacts]
            default: order = [.actions, .tests, .problems, .artifacts]
            }
        } else if facts.delivered {
            order = [.artifacts, .actions, .tests, .problems]
        } else {
            order = [.actions, .tests, .problems, .artifacts]
        }

        var omissions: [Omission] = []
        if facts.issuesKnownEmpty { omissions.append(.noIssues) }
        if facts.artifactsKnownEmpty { omissions.append(.noArtifacts) }
        switch facts.tests {
        case .present: break
        case .notRun: omissions.append(.testsNotRun)
        case .absent: omissions.append(.noTests)
        }
        let dropped = Set(omissions.flatMap { omission -> [BuildPart] in
            switch omission {
            case .noIssues: [.problems]
            case .noArtifacts: [.artifacts]
            case .testsNotRun, .noTests: [.tests]
            }
        })
        order.removeAll { dropped.contains($0) }

        parts = order
        expanded = Set(order.prefix(facts.isFailed ? 2 : 1))
        self.omissions = omissions
    }

    /// The part that holds the reason of a failure: the category when it is known, else what Apple counted on the build.
    static func cause(of facts: Facts) -> BuildPart {
        if let category = facts.category {
            switch category {
            case .tests, .flakyTest: return .tests
            case .compilation, .signing, .configuration, .distribution: return .problems
            case .infrastructure, .other: return .actions
            }
        }
        if (facts.issueCounts?.testFailures ?? 0) > 0 { return .tests }
        if (facts.issueCounts?.errors ?? 0) > 0 { return .problems }
        return .actions
    }

    /// The line at the foot of the card: “No issues · no artifacts · tests not run”.
    var footnote: String? {
        let words = omissions.map { omission -> String in
            switch omission {
            case .noIssues: String(localized: "no issues", comment: "Foot of a build's detail card, in lowercase: the build has no issue to list")
            case .noArtifacts: String(localized: "no artifacts", comment: "Foot of a build's detail card, in lowercase: the build produced no file")
            case .testsNotRun: String(localized: "tests not run", comment: "Foot of a build's detail card, in lowercase: the build stopped before its tests")
            case .noTests: String(localized: "no tests in this workflow", comment: "Foot of a build's detail card, in lowercase")
            }
        }
        guard let first = words.first else { return nil }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + words.dropFirst()).joined(separator: " · ")
    }
}

/// What a part says on its line while it is closed: a count or two, drawn only from what the app already knows.
nonisolated struct BuildPartCounter: Equatable, Sendable {
    struct Piece: Equatable, Sendable {
        var text: String
        /// Failures and errors: drawn in the failure colour.
        var isAlert = false
    }

    var pieces: [Piece] = []

    var text: String { pieces.map(\.text).joined(separator: " · ") }

    var isEmpty: Bool { pieces.isEmpty }

    private static var pending: BuildPartCounter {
        BuildPartCounter(pieces: [Piece(text: String(localized: "pending", comment: "A part of a running build's detail card that cannot have anything to show yet"))])
    }

    /// - Parameter results: the test results, once they are all read.
    static func tests(isRunning: Bool, counts: CIIssueCounts?, results: [CITestResult]?) -> BuildPartCounter {
        if let results {
            let failed = results.filter(\.status.isFailure).count
            let passed = results.filter { $0.status == .success }.count
            var pieces: [Piece] = []
            if failed > 0 { pieces.append(Piece(text: String(localized: "\(failed) failed", comment: "Failed tests, on a closed part of a build's detail card"), isAlert: true)) }
            if passed > 0 { pieces.append(Piece(text: String(localized: "\(passed) passed", comment: "Passed tests, on a closed part of a build's detail card"))) }
            return BuildPartCounter(pieces: pieces)
        }
        if let failed = counts?.testFailures {
            return BuildPartCounter(pieces: [
                failed > 0
                    ? Piece(text: String(localized: "\(failed) failed", comment: "Failed tests, on a closed part of a build's detail card"), isAlert: true)
                    : Piece(text: String(localized: "no failures", comment: "A build's tests, on a closed part of its detail card: none failed")),
            ])
        }
        return isRunning ? pending : BuildPartCounter()
    }

    static func problems(isRunning: Bool, isFailedBuild: Bool, counts: CIIssueCounts?) -> BuildPartCounter {
        guard let counts else { return isRunning ? pending : BuildPartCounter() }
        var pieces: [Piece] = []
        if let errors = counts.errors, errors > 0 {
            pieces.append(Piece(text: String(localized: "\(errors) errors", comment: "Errors, on a closed part of a build's detail card"), isAlert: true))
        } else if isFailedBuild {
            pieces.append(Piece(text: String(localized: "no errors", comment: "A failed build's issues, on a closed part of its detail card: no error")))
        }
        let warnings = (counts.warnings ?? 0) + (counts.analyzerWarnings ?? 0)
        if warnings > 0 { pieces.append(Piece(text: String(localized: "\(warnings) warnings", comment: "Warnings, on a closed part of a build's detail card"))) }
        return BuildPartCounter(pieces: pieces)
    }

    /// - Parameters:
    ///   - launched: the actions that started.
    ///   - clock: the build's total time, when it has one.
    static func actions(count: Int, launched: Int, finished: Int, isRunning: Bool, clock: String?) -> BuildPartCounter {
        guard count > 0 else { return isRunning ? pending : BuildPartCounter() }
        if isRunning {
            return BuildPartCounter(pieces: [
                Piece(text: String(localized: "\(finished) of \(count)", comment: "Actions of a running build that have ended, out of all of them")),
                Piece(text: String(localized: "running", comment: "State of a running build, in lowercase")),
            ])
        }
        var pieces = [Piece(text: String(localized: "\(count) actions", comment: "Number of actions of a build, on a closed part of its detail card"))]
        if launched < count {
            pieces.append(Piece(text: String(localized: "\(launched) launched", comment: "How many of a build's actions started, when some never did")))
        } else if let clock {
            pieces.append(Piece(text: clock))
        }
        return BuildPartCounter(pieces: pieces)
    }

    /// - Parameter artifacts: the files, once every finished action has been asked for its own.
    static func artifacts(isRunning: Bool, artifacts: [CIArtifact]?) -> BuildPartCounter {
        guard let artifacts else { return isRunning ? pending : BuildPartCounter() }
        guard !artifacts.isEmpty else { return BuildPartCounter() }
        var pieces = [Piece(text: String(localized: "\(artifacts.count) artifacts", comment: "Number of files a build produced, on a closed part of its detail card"))]
        let sizes = artifacts.compactMap(\.fileSize)
        if sizes.count == artifacts.count {
            pieces.append(Piece(text: sizes.reduce(0, +).formatted(.byteCount(style: .file))))
        }
        return BuildPartCounter(pieces: pieces)
    }
}

nonisolated extension BuildSheetOrder.Facts {
    /// What the snapshot, and the extras already in memory, say of a build. Asks for nothing.
    init(run: CIBuildRun, actions: [CIBuildAction], workflow: CIWorkflow?, category: FailureCategory?, extras: BuildExtras?) {
        let isRunning = run.executionProgress == .pending || run.executionProgress == .running
        self.init(isRunning: isRunning, completion: run.completionStatus, category: category, issueCounts: run.issueCounts)

        let archived = actions.contains { $0.actionType == .archive && $0.executionProgress == .complete && $0.completionStatus == .succeeded }
        delivered = !isRunning && run.completionStatus == .succeeded && (archived || !(extras?.betaBuilds ?? []).isEmpty)

        let testActions = actions.filter { $0.actionType == .test }
        let configured = workflow?.actions.contains { $0.actionType == .test } ?? false
        if isRunning {
            tests = testActions.isEmpty && !configured ? .absent : .present
        } else if testActions.contains(where: { $0.startedDate != nil && $0.completionStatus != .skipped }) {
            tests = .present
        } else {
            tests = testActions.isEmpty && !configured ? .absent : .notRun
        }

        if !isRunning {
            let counted = run.issueCounts?.total ?? (!actions.isEmpty && actions.allSatisfy { $0.issueCounts != nil } ? actions.reduce(0) { $0 + ($1.issueCounts?.total ?? 0) } : nil)
            let read = extras?.issuesComplete == true && extras?.issuesByAction.values.allSatisfy(\.isEmpty) == true
            issuesKnownEmpty = counted == 0 || read
        }
        artifactsKnownEmpty = !isRunning && extras?.artifactsComplete == true && extras?.artifactsByAction.values.allSatisfy(\.isEmpty) == true
    }

    /// The category of a failed build once its issues and test results are in memory: the same rules as “In Brief”.
    static func category(of run: CIBuildRun, actions: [CIBuildAction], extras: BuildExtras?) -> FailureCategory? {
        guard BuildFailurePrompt.isOffered(for: run), let extras, extras.issuesComplete, extras.testsComplete else { return nil }
        let errors = actions.flatMap { extras.issuesByAction[$0.id] ?? [] }.filter { $0.type == .error }
        let failed = actions.flatMap { extras.testsByAction[$0.id] ?? [] }.filter(\.status.isFailure)
        return FailureCategory.decide(completion: run.completionStatus, errors: errors, failedTests: failed)
    }
}
