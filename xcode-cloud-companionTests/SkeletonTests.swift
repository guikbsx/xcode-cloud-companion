import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct SkeletonTests {
    private func action(_ type: CIActionType, progress: CIExecutionProgress = .complete, issues: Int? = nil) -> CIBuildAction {
        CIBuildAction(
            id: UUID().uuidString, buildRunID: "run", name: "Action", actionType: type, startedDate: nil, finishedDate: nil, executionProgress: progress,
            completionStatus: nil, isRequiredToPass: nil, issueCounts: issues.map { CIIssueCounts(errors: $0) }
        )
    }

    @Test func theInBriefCardIsASkeletonUntilItsLoadEndsWithoutARecord() {
        #expect(SkeletonRules.failureInsight(hasRecord: false, isLoading: false, hasAttempted: false), "from the first frame")
        #expect(SkeletonRules.failureInsight(hasRecord: false, isLoading: true, hasAttempted: true), "another opening is loading it")
        #expect(!SkeletonRules.failureInsight(hasRecord: false, isLoading: false, hasAttempted: true), "no record came: the card goes")
        #expect(!SkeletonRules.failureInsight(hasRecord: true, isLoading: true, hasAttempted: false), "a known record is shown")
    }

    @Test func theLogExcerptCardIsASkeletonWhileTheLogIsDownloadedOrReadOrNotLookedAtYet() {
        #expect(SkeletonRules.logExcerpt(hasOutcome: false, isWorking: false, hasAttempted: false), "from the first frame, while the disk is first looked at")
        #expect(SkeletonRules.logExcerpt(hasOutcome: false, isWorking: true, hasAttempted: true), "the download")
        #expect(SkeletonRules.logExcerpt(hasOutcome: true, isWorking: true, hasAttempted: true), "the reading, even over an earlier answer")
        #expect(!SkeletonRules.logExcerpt(hasOutcome: false, isWorking: false, hasAttempted: true), "nothing came: the button")
        #expect(!SkeletonRules.logExcerpt(hasOutcome: true, isWorking: false, hasAttempted: false), "an answer known from before is shown at once")
    }

    @Test func theLogExcerptComesFromTheFirstActionThatFailed() {
        func action(_ id: String, _ status: CICompletionStatus?, started: Double, progress: CIExecutionProgress = .complete) -> CIBuildAction {
            CIBuildAction(
                id: id, buildRunID: "run", name: id, actionType: .build, startedDate: Date(timeIntervalSince1970: started), finishedDate: nil,
                executionProgress: progress, completionStatus: status, isRequiredToPass: nil
            )
        }
        let actions = [action("late", .failed, started: 30), action("ok", .succeeded, started: 5), action("first", .errored, started: 10), action("running", nil, started: 1, progress: .running)]

        #expect(LogExcerptTarget.action(in: actions)?.id == "first")
        #expect(LogExcerptTarget.action(in: [action("ok", .succeeded, started: 5), action("skipped", .skipped, started: 6)]) == nil)
        #expect(LogExcerptTarget.action(in: []) == nil)
    }

    @Test func theTestFlightCardNeedsASucceededBuildOfAWorkflowThatShips() {
        #expect(SkeletonRules.testFlightCard(shipsToTestFlight: true, isSucceeded: true, hasBuilds: false, loadEnded: false))
        #expect(!SkeletonRules.testFlightCard(shipsToTestFlight: false, isSucceeded: true, hasBuilds: false, loadEnded: false))
        #expect(!SkeletonRules.testFlightCard(shipsToTestFlight: true, isSucceeded: false, hasBuilds: false, loadEnded: false))
        #expect(!SkeletonRules.testFlightCard(shipsToTestFlight: true, isSucceeded: true, hasBuilds: false, loadEnded: true), "the load ended with nothing")
        #expect(!SkeletonRules.testFlightCard(shipsToTestFlight: true, isSucceeded: true, hasBuilds: true, loadEnded: false))
    }

    @Test func theTestsTabNeedsAFinishedTestActionAndNothingKnownYet() {
        let finished = [action(.build), action(.test)]
        #expect(SkeletonRules.testsTab(isPending: true, hasResults: false, actions: finished))
        #expect(!SkeletonRules.testsTab(isPending: true, hasResults: false, actions: [action(.build)]), "no test action")
        #expect(!SkeletonRules.testsTab(isPending: true, hasResults: false, actions: [action(.test, progress: .running)]), "nothing to read yet")
        #expect(!SkeletonRules.testsTab(isPending: true, hasResults: true, actions: finished), "results already stand")
        #expect(!SkeletonRules.testsTab(isPending: false, hasResults: false, actions: finished), "loaded or failed")
    }

    @Test func theIssuesAndArtifactsTabsWaitOnTheActionsTheyAskAbout() {
        #expect(SkeletonRules.issuesTab(isPending: true, hasRows: false, actions: [action(.build)]), "issues unknown")
        #expect(SkeletonRules.issuesTab(isPending: true, hasRows: false, actions: [action(.build, issues: 3)]))
        #expect(!SkeletonRules.issuesTab(isPending: true, hasRows: false, actions: [action(.build, issues: 0)]), "Apple counted none")
        #expect(!SkeletonRules.issuesTab(isPending: false, hasRows: false, actions: [action(.build)]))
        #expect(SkeletonRules.artifactsTab(isPending: true, hasRows: false, actions: [action(.archive)]))
        #expect(!SkeletonRules.artifactsTab(isPending: true, hasRows: false, actions: [action(.archive, progress: .running)]))
        #expect(!SkeletonRules.artifactsTab(isPending: true, hasRows: true, actions: [action(.archive)]))
    }

    @Test func theTestFlightPillNeedsAShippedBuildWhoseReadingHasNotEnded() {
        #expect(SkeletonRules.testFlightPill(hasShippedRun: true, hasText: false, loadEnded: false))
        #expect(!SkeletonRules.testFlightPill(hasShippedRun: false, hasText: false, loadEnded: false), "no workflow ships")
        #expect(!SkeletonRules.testFlightPill(hasShippedRun: true, hasText: true, loadEnded: false))
        #expect(!SkeletonRules.testFlightPill(hasShippedRun: true, hasText: false, loadEnded: true), "skipped or failed")
    }

    @Test func theSidebarCycleCardWaitsOnlyWhenThereIsAPlanAndAMeasure() {
        #expect(SkeletonRules.sidebarCycle(hasPlan: true, isMeasuring: true))
        #expect(!SkeletonRules.sidebarCycle(hasPlan: false, isMeasuring: true), "the prompt to set a plan stays")
        #expect(!SkeletonRules.sidebarCycle(hasPlan: true, isMeasuring: false))
    }

    @Test func aWorkflowSheetWaitsForItsOwnRequestOnlyWithNothingCached() {
        #expect(SkeletonRules.workflowSheet(isCached: false, loadEnded: false))
        #expect(!SkeletonRules.workflowSheet(isCached: true, loadEnded: false))
        #expect(!SkeletonRules.workflowSheet(isCached: false, loadEnded: true))
    }

    @Test func everyLoadStateIsPendingOrNot() {
        #expect(ExtrasLoadState.idle.isPending && ExtrasLoadState.loading(done: 1, total: 3).isPending)
        #expect(!ExtrasLoadState.loaded.isPending && !ExtrasLoadState.failed(message: "x", done: 0, total: 1).isPending)
    }

    @Test func everySkeletonHasItsSampleData() {
        #expect(FailureInsightRecord.placeholder.headline != nil)
        #expect(CIBetaBuild.placeholder.version != nil)
        #expect(TestRow.placeholders.count == 4)
        #expect(IssueGroup.placeholder.rows.count == 4)
        #expect(CIArtifact.placeholders.count == 4)
        #expect(OverviewModel.WorkflowRow.placeholders.count == 3)
        #expect(OverviewModel.WorkflowSegment.placeholders.count == 3)
        #expect(BuildCost.placeholder.minutes > 0)
        #expect(AppOverviewModel.Cycle.placeholder.segments.count == 3 && !AppOverviewModel.Cycle.placeholder.isMeasuring)
        #expect(WorkflowDetailModel.placeholderInfo.count == 4 && WorkflowDetailModel.placeholderConditions.count == 3)
        #expect(TestHealthReport.placeholder.analyzedBuilds > 0 && !TestHealthReport.placeholder.flaky.isEmpty)
        #expect(CycleCard.Content.placeholder.fractionUsed > 0)
    }

    @Test func theSampleRowsOfOneSkeletonAreDistinctRows() {
        #expect(Set(TestRow.placeholders.map(\.id)).count == 4)
        #expect(Set(IssueGroup.placeholder.rows.map(\.id)).count == 4)
        #expect(Set(CIArtifact.placeholders.map(\.id)).count == 4)
    }
}
