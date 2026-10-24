import Foundation
import Testing
@testable import XcodeCloudCompanion

struct BuildSheetOrderTests {
    private func facts(
        running: Bool = false, _ completion: CICompletionStatus? = .succeeded, category: FailureCategory? = nil, counts: CIIssueCounts? = nil,
        delivered: Bool = false, tests: BuildSheetOrder.TestsPresence = .present, noIssues: Bool = false, noArtifacts: Bool = false
    ) -> BuildSheetOrder.Facts {
        BuildSheetOrder.Facts(
            isRunning: running, completion: completion, category: category, issueCounts: counts, delivered: delivered, tests: tests,
            issuesKnownEmpty: noIssues, artifactsKnownEmpty: noArtifacts
        )
    }

    @Test(arguments: [
        (FailureCategory.tests, [BuildPart.tests, .problems, .actions, .artifacts]),
        (.flakyTest, [.tests, .problems, .actions, .artifacts]),
        (.compilation, [.problems, .tests, .actions, .artifacts]),
        (.signing, [.problems, .tests, .actions, .artifacts]),
        (.configuration, [.problems, .tests, .actions, .artifacts]),
        (.distribution, [.problems, .tests, .actions, .artifacts]),
        (.infrastructure, [.actions, .tests, .problems, .artifacts]),
        (.other, [.actions, .tests, .problems, .artifacts]),
    ])
    func aFailedBuildStartsWithThePartOfItsCause(category: FailureCategory, order: [BuildPart]) {
        let result = BuildSheetOrder(facts(.failed, category: category))
        #expect(result.parts == order)
        #expect(result.expanded == Set(order.prefix(2)), "the first two are open")
    }

    @Test func anErroredBuildFollowsTheSameRule() {
        #expect(BuildSheetOrder(facts(.errored, category: .infrastructure)).parts.first == .actions)
        #expect(BuildSheetOrder(facts(.errored, category: .compilation)).parts.first == .problems)
    }

    @Test func aRunningBuildShowsItsActionsAndKeepsTheRestClosed() {
        let result = BuildSheetOrder(facts(running: true, nil, counts: CIIssueCounts(errors: 2)))
        #expect(result.parts == [.actions, .tests, .problems, .artifacts])
        #expect(result.expanded == [.actions])
    }

    @Test func aSucceededBuildStartsWithItsFilesWhenItDeliveredAndWithItsActionsOtherwise() {
        let delivered = BuildSheetOrder(facts(delivered: true))
        #expect(delivered.parts == [.artifacts, .actions, .tests, .problems])
        #expect(delivered.expanded == [.artifacts])

        let plain = BuildSheetOrder(facts())
        #expect(plain.parts == [.actions, .tests, .problems, .artifacts])
        #expect(plain.expanded == [.actions])
        #expect(BuildSheetOrder(facts(.canceled)).parts.first == .actions)
    }

    @Test func withoutACategoryTheCountsOnTheBuildDecide() {
        #expect(BuildSheetOrder(facts(.failed, counts: CIIssueCounts(errors: 2, testFailures: 3))).parts.first == .tests)
        #expect(BuildSheetOrder(facts(.failed, counts: CIIssueCounts(errors: 2, testFailures: 0))).parts.first == .problems)
        #expect(BuildSheetOrder(facts(.failed, counts: CIIssueCounts(errors: 0, testFailures: 0))).parts.first == .actions)
        #expect(BuildSheetOrder(facts(.failed, counts: nil)).parts.first == .actions, "nothing is known")
    }

    @Test func theCategoryOutweighsTheCountsOnceItIsKnown() {
        let counts = CIIssueCounts(errors: 0, testFailures: 4)
        #expect(BuildSheetOrder(facts(.failed, category: .compilation, counts: counts)).parts.first == .problems)
    }

    @Test func anEmptyPartHasNoLineAndIsToldAtTheFoot() {
        let result = BuildSheetOrder(facts(.failed, category: .compilation, tests: .notRun, noArtifacts: true))
        #expect(result.parts == [.problems, .actions])
        #expect(result.omissions == [.noArtifacts, .testsNotRun])
        #expect(result.expanded == [.problems, .actions])
        #expect(result.footnote == String(localized: "no artifacts").prefix(1).uppercased() + String(localized: "no artifacts").dropFirst() + " · " + String(localized: "tests not run"))
    }

    @Test func aWorkflowWithoutTestsAndABuildWithoutIssuesLoseTheirLines() {
        let result = BuildSheetOrder(facts(delivered: true, tests: .absent, noIssues: true))
        #expect(result.parts == [.artifacts, .actions])
        #expect(result.omissions == [.noIssues, .noTests])
    }

    @Test func nothingOmittedMeansNoFootnote() {
        #expect(BuildSheetOrder(facts()).footnote == nil)
    }

    // MARK: - Facts of a build

    private let day = Date(timeIntervalSince1970: 1_791_547_200)

    private func run(_ completion: CICompletionStatus?, progress: CIExecutionProgress = .complete, counts: CIIssueCounts? = nil) -> CIBuildRun {
        CIBuildRun(
            id: "run", productID: "p", number: 1, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(60), executionProgress: progress,
            completionStatus: completion, startReason: nil, workflowID: "wf", workflowName: "Release", sourceBranchOrTag: "main", issueCounts: counts
        )
    }

    private func action(_ type: CIActionType, id: String = UUID().uuidString, started: Bool = true, completion: CICompletionStatus? = .succeeded, counts: CIIssueCounts? = nil) -> CIBuildAction {
        CIBuildAction(
            id: id, buildRunID: "run", name: "\(type)", actionType: type, startedDate: started ? day : nil, finishedDate: started ? day.addingTimeInterval(30) : nil,
            executionProgress: started ? .complete : .pending, completionStatus: completion, isRequiredToPass: true, issueCounts: counts
        )
    }

    private func workflow(testing: Bool) -> CIWorkflow {
        var workflow = CIWorkflow(id: "wf", name: "Release", testDestinationCounts: [])
        if testing { workflow.actions = [CIWorkflowAction(name: "Test", actionType: .test)] }
        return workflow
    }

    @Test func factsReadTheTestsFromTheActionsThatRan() {
        func tests(_ actions: [CIBuildAction], workflow: CIWorkflow? = nil, run: CIBuildRun? = nil) -> BuildSheetOrder.TestsPresence {
            BuildSheetOrder.Facts(run: run ?? self.run(.failed), actions: actions, workflow: workflow, category: nil, extras: nil).tests
        }
        #expect(tests([action(.build), action(.test)]) == .present)
        #expect(tests([action(.build, completion: .failed), action(.test, started: false, completion: nil)], workflow: workflow(testing: true)) == .notRun)
        #expect(tests([action(.build, completion: .failed)], workflow: workflow(testing: true)) == .notRun, "the workflow tests, none started")
        #expect(tests([action(.build)], workflow: workflow(testing: false)) == .absent)
        #expect(tests([action(.build)], workflow: nil) == .absent)
        #expect(tests([action(.build)], workflow: workflow(testing: true), run: run(nil, progress: .running)) == .present, "it may still come")
    }

    @Test func factsCallABuildDeliveredWhenItArchivedOrReachedTestFlight() {
        func delivered(_ actions: [CIBuildAction], extras: BuildExtras? = nil, run: CIBuildRun? = nil) -> Bool {
            BuildSheetOrder.Facts(run: run ?? self.run(.succeeded), actions: actions, workflow: nil, category: nil, extras: extras).delivered
        }
        #expect(delivered([action(.build), action(.archive)]))
        #expect(!delivered([action(.build), action(.test)]))
        #expect(!delivered([action(.archive, completion: .failed)]))
        #expect(!delivered([action(.archive)], run: run(.failed)))
        #expect(delivered([action(.build)], extras: BuildExtras(betaBuilds: [CIBetaBuild.placeholder])))
    }

    @Test func factsKnowThatNothingIsToBeListedOnlyFromWhatIsAlreadyThere() {
        func facts(_ run: CIBuildRun, _ actions: [CIBuildAction] = [], extras: BuildExtras? = nil) -> BuildSheetOrder.Facts {
            BuildSheetOrder.Facts(run: run, actions: actions, workflow: nil, category: nil, extras: extras)
        }
        #expect(facts(run(.succeeded, counts: CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 0, warnings: 0))).issuesKnownEmpty)
        #expect(!facts(run(.succeeded, counts: CIIssueCounts(warnings: 6))).issuesKnownEmpty)
        #expect(!facts(run(.succeeded)).issuesKnownEmpty, "Apple counted nothing: unknown, not zero")
        #expect(!facts(run(nil, progress: .running, counts: CIIssueCounts(errors: 0))).issuesKnownEmpty, "a running build may still find some")
        #expect(facts(run(.succeeded), [action(.build, counts: CIIssueCounts(errors: 0, warnings: 0))]).issuesKnownEmpty, "every action counted none")

        var read = BuildExtras()
        read.artifactsComplete = true
        #expect(facts(run(.failed), extras: read).artifactsKnownEmpty)
        read.artifactsByAction = ["a": [CIArtifact.placeholders[0]]]
        #expect(!facts(run(.failed), extras: read).artifactsKnownEmpty)
        #expect(!facts(run(.failed)).artifactsKnownEmpty)
    }

    @Test func theCategoryIsKnownOnceIssuesAndTestsAreRead() {
        let build = action(.build, id: "b")
        var extras = BuildExtras()
        #expect(BuildSheetOrder.Facts.category(of: run(.failed), actions: [build], extras: extras) == nil, "nothing read")
        extras.issuesComplete = true
        extras.testsComplete = true
        extras.issuesByAction = ["b": [CIIssue(id: "i", buildActionID: "b", type: .error, message: "x", category: "xcodebuild", file: nil)]]
        #expect(BuildSheetOrder.Facts.category(of: run(.failed), actions: [build], extras: extras) == .compilation)
        #expect(BuildSheetOrder.Facts.category(of: run(.succeeded), actions: [build], extras: extras) == nil, "only a failed build has one")
    }

    // MARK: - Counters

    @Test func aClosedPartSaysWhatTheAppKnows() {
        let failed = CITestResult(id: "t1", buildActionID: "a", className: "C", name: "x", status: .failure, message: nil, file: nil, devices: [])
        let passed = CITestResult(id: "t2", buildActionID: "a", className: "C", name: "y", status: .success, message: nil, file: nil, devices: [])

        #expect(BuildPartCounter.tests(isRunning: false, counts: CIIssueCounts(testFailures: 3), results: nil).pieces == [.init(text: String(localized: "\(3) failed"), isAlert: true)])
        let read = BuildPartCounter.tests(isRunning: false, counts: nil, results: [failed, passed, passed])
        #expect(read.pieces.map(\.text) == [String(localized: "\(1) failed"), String(localized: "\(2) passed")])
        #expect(read.pieces.map(\.isAlert) == [true, false])
        #expect(BuildPartCounter.tests(isRunning: false, counts: nil, results: nil).isEmpty, "unknown: only the name")
        #expect(BuildPartCounter.tests(isRunning: true, counts: nil, results: nil).text == String(localized: "pending"))

        let problems = BuildPartCounter.problems(isRunning: false, isFailedBuild: true, counts: CIIssueCounts(errors: 2, warnings: 3))
        #expect(problems.pieces.map(\.isAlert) == [true, false])
        #expect(BuildPartCounter.problems(isRunning: false, isFailedBuild: true, counts: CIIssueCounts(errors: 0, warnings: 2)).pieces.count == 2, "a failed build says it has no errors")
        #expect(BuildPartCounter.problems(isRunning: false, isFailedBuild: false, counts: CIIssueCounts(errors: 0, warnings: 6)).pieces.count == 1)
        #expect(BuildPartCounter.problems(isRunning: false, isFailedBuild: false, counts: nil).isEmpty)

        #expect(BuildPartCounter.actions(count: 3, launched: 3, finished: 3, isRunning: false, clock: "6:12").text == "\(String(localized: "\(3) actions")) · 6:12")
        #expect(BuildPartCounter.actions(count: 3, launched: 1, finished: 1, isRunning: false, clock: "1:48").pieces.count == 2)
        #expect(BuildPartCounter.actions(count: 2, launched: 2, finished: 1, isRunning: true, clock: "0:20").pieces.count == 2)

        var big = CIArtifact.placeholders[0]
        big = CIArtifact(id: big.id, buildActionID: big.buildActionID, fileType: big.fileType, fileName: big.fileName, fileSize: 1_000_000, downloadURL: nil)
        #expect(BuildPartCounter.artifacts(isRunning: false, artifacts: [big, big]).pieces.count == 2)
        #expect(BuildPartCounter.artifacts(isRunning: false, artifacts: nil).isEmpty)
        #expect(BuildPartCounter.artifacts(isRunning: true, artifacts: nil).text == String(localized: "pending"))
    }
}
