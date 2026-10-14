import AppKit
import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildETATests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")

    /// A finished build of a workflow that took `minutes`, created `daysAgo` days before now.
    private func finished(
        _ number: Int, minutes: Double, daysAgo: Double, workflow: String? = "wf", status: CICompletionStatus = .succeeded
    ) -> CIBuildRun {
        let created = now.addingTimeInterval(-daysAgo * 86_400)
        return CIBuildRun(
            id: "done-\(workflow ?? "none")-\(number)", productID: "p", number: number, createdDate: created,
            startedDate: created, finishedDate: created.addingTimeInterval(minutes * 60), executionProgress: .complete,
            completionStatus: status, startReason: nil, workflowID: workflow, workflowName: "Release", sourceBranchOrTag: nil
        )
    }

    private func running(
        _ number: Int, startedMinutesAgo: Double?, workflow: String? = "wf", progress: CIExecutionProgress = .running, product: String = "p"
    ) -> CIBuildRun {
        CIBuildRun(
            id: "run-\(product)-\(number)", productID: product, number: number, createdDate: now.addingTimeInterval(-(startedMinutesAgo ?? 1) * 60 - 30),
            startedDate: startedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, finishedDate: nil, executionProgress: progress,
            completionStatus: nil, startReason: nil, workflowID: workflow, workflowName: "Release", sourceBranchOrTag: "main"
        )
    }

    /// Five succeeded builds of 10 minutes: the median is 10.
    private var history: [CIBuildRun] {
        (1...5).map { finished($0, minutes: 10, daysAgo: Double($0)) }
    }

    @Test func theEstimateIsTheMedianMinusTheTimeElapsed() throws {
        let build = running(9, startedMinutesAgo: 6)
        let eta = try #require(BuildETA(run: build, among: history + [build], now: now))

        #expect(eta.medianDuration == 600)
        #expect(eta.remaining(at: now) == 240)
        #expect(eta.expectedEnd == now.addingTimeInterval(240))
        #expect(eta.display(at: now) == .minutes(4))
        #expect(abs(eta.progress(at: now) - 0.6) < 0.0001)
    }

    @Test func theMedianIsOfTheThirtyNewestSucceededBuilds() throws {
        let recent = (1...30).map { finished($0, minutes: 10, daysAgo: Double($0)) }
        let ancient = (31...80).map { finished($0, minutes: 120, daysAgo: Double($0)) }
        let build = running(99, startedMinutesAgo: 1)

        let eta = try #require(BuildETA(run: build, among: recent + ancient, now: now))

        #expect(eta.medianDuration == 600)
        #expect(eta.sampleSize == 30)
    }

    @Test func failedCanceledOtherWorkflowAndUnfinishedBuildsDoNotCount() {
        let build = running(9, startedMinutesAgo: 1)
        let noise = [
            finished(1, minutes: 99, daysAgo: 1, status: .failed), finished(2, minutes: 99, daysAgo: 2, status: .canceled),
            finished(3, minutes: 99, daysAgo: 3, workflow: "other"), running(4, startedMinutesAgo: 50),
            finished(5, minutes: 10, daysAgo: 5), finished(6, minutes: 10, daysAgo: 6),
        ]

        #expect(BuildETA(run: build, among: noise + [build], now: now) == nil)
        let enough = noise + [finished(7, minutes: 10, daysAgo: 7)]
        #expect(BuildETA(run: build, among: enough + [build], now: now)?.medianDuration == 600)
    }

    @Test func fewerThanThreeBuildsGiveNoEstimate() {
        let build = running(9, startedMinutesAgo: 1)

        #expect(BuildETA(run: build, among: Array(history.prefix(2)) + [build], now: now) == nil)
        #expect(BuildETA(run: build, among: Array(history.prefix(3)) + [build], now: now) != nil)
    }

    @Test func aQueuedBuildOrOneWithoutAWorkflowGivesNoEstimate() {
        let queued = running(9, startedMinutesAgo: nil, progress: .pending)
        let noWorkflow = running(10, startedMinutesAgo: 1, workflow: nil)

        #expect(BuildETA(run: queued, among: history + [queued], now: now) == nil)
        #expect(BuildETA(run: noWorkflow, among: history + [noWorkflow], now: now) == nil)
    }

    @Test func onceTheMedianIsPassedTheEstimateIsGone() {
        let late = running(9, startedMinutesAgo: 10)
        let later = running(10, startedMinutesAgo: 45)

        #expect(BuildETA(run: late, among: history + [late], now: now) == nil)
        #expect(BuildETA(run: later, among: history + [later], now: now) == nil)
    }

    @Test func theDisplayIsNeverZeroNorNegative() {
        #expect(BuildETA.display(remaining: -5) == nil)
        #expect(BuildETA.display(remaining: 0) == nil)
        #expect(BuildETA.display(remaining: 0.4) == .underAMinute)
        #expect(BuildETA.display(remaining: 59.9) == .underAMinute)
        #expect(BuildETA.display(remaining: 60) == .minutes(1))
        #expect(BuildETA.display(remaining: 89) == .minutes(1))
        #expect(BuildETA.display(remaining: 90) == .minutes(2))
        #expect(BuildETA.display(remaining: 240) == .minutes(4))
        #expect(BuildETA.display(remaining: 3_900) == .minutes(65))
    }

    @Test func theNextChangeIsWhenTheTextDiffers() throws {
        for remaining in [0.5, 30, 59.9, 60, 75, 89.9, 90, 100, 149, 150, 239, 240, 3_600] as [TimeInterval] {
            let change = try #require(BuildETA.nextChange(remaining: remaining, from: now))
            let later = remaining - change.timeIntervalSince(now)

            #expect(change > now)
            #expect(change.timeIntervalSince(now) <= 60.2)
            #expect(BuildETA.display(remaining: later) != BuildETA.display(remaining: remaining), "remaining \(remaining)")
            // And not before: the text just ahead of the change is still the current one.
            let before = remaining - (change.timeIntervalSince(now) - 0.2)
            #expect(BuildETA.display(remaining: before) == BuildETA.display(remaining: remaining), "remaining \(remaining)")
        }
        #expect(BuildETA.nextChange(remaining: 0, from: now) == nil)
    }

    // MARK: - Several builds, several accounts

    @Test func severalBuildsGiveTheirCountAndTheNearestEnd() {
        let near = running(11, startedMinutesAgo: 8)
        let far = running(12, startedMinutesAgo: 2)
        let snapshot = BuildSnapshot(runs: history + [far, near])

        let summary = RunningBuildsETA(snapshots: [snapshot], now: now)

        #expect(summary.runningCount == 2)
        #expect(summary.remaining == 120)
        #expect(summary.display == .minutes(2))
    }

    @Test func aBuildWithoutAnEstimateCountsButDoesNotSetTheTime() {
        let queued = running(11, startedMinutesAgo: nil, progress: .pending)
        let unknown = running(12, startedMinutesAgo: 3, workflow: "fresh")
        let known = running(13, startedMinutesAgo: 4)

        let onlyUnknown = RunningBuildsETA(snapshots: [BuildSnapshot(runs: history + [queued, unknown])], now: now)
        let mixed = RunningBuildsETA(snapshots: [BuildSnapshot(runs: history + [queued, unknown, known])], now: now)

        #expect(onlyUnknown.runningCount == 2)
        #expect(onlyUnknown.remaining == nil)
        #expect(mixed.runningCount == 3)
        #expect(mixed.remaining == 360)
    }

    @Test func theCountIsAcrossAccountsAndTheTimeIsTheNearestOne() {
        let first = BuildSnapshot(runs: history + [running(11, startedMinutesAgo: 1)])
        let second = BuildSnapshot(runs: history.map { build in
            CIBuildRun(
                id: "b-" + build.id, productID: build.productID, number: build.number, createdDate: build.createdDate, startedDate: build.startedDate,
                finishedDate: build.startedDate.map { $0.addingTimeInterval(300) }, executionProgress: .complete, completionStatus: .succeeded,
                startReason: nil, workflowID: build.workflowID, workflowName: nil, sourceBranchOrTag: nil
            )
        } + [running(21, startedMinutesAgo: 2, product: "q")])

        let summary = RunningBuildsETA(snapshots: [first, second], now: now)

        #expect(summary.runningCount == 2)
        #expect(summary.remaining == 180)
        #expect(RunningBuildsETA(snapshots: [first], now: now).remaining == 540)
        #expect(RunningBuildsETA(snapshots: [], now: now).runningCount == 0)
    }

    @Test func nothingRunningMeansNothingToSay() {
        let summary = RunningBuildsETA(snapshots: [BuildSnapshot(runs: history)], now: now)

        #expect(summary.runningCount == 0)
        #expect(summary.remaining == nil)
        #expect(summary.nextChange == nil)
        #expect(BuildETAFormat.barText(runningCount: 0, display: .minutes(4), locale: english) == nil)
    }

    @Test func theNextChangeIsTheEarliestOfTheEstimates() throws {
        let one = running(11, startedMinutesAgo: 1)
        let other = running(12, startedMinutesAgo: 7.5)

        let summary = RunningBuildsETA(snapshots: [BuildSnapshot(runs: history + [one, other])], now: now)

        let change = try #require(summary.nextChange)
        #expect(change.timeIntervalSince(now) < 40)
    }

    // MARK: - Words

    @Test func theBarSaysTheTimeLeftWithTheCountOnlyWhenSeveralRun() {
        #expect(BuildETAFormat.barText(runningCount: 1, display: .minutes(4), locale: english) == "~4 min")
        #expect(BuildETAFormat.barText(runningCount: 2, display: .minutes(4), locale: english) == "2 · ~4 min")
        #expect(BuildETAFormat.barText(runningCount: 1, display: .underAMinute, locale: english) == "< 1 min")
        #expect(BuildETAFormat.barText(runningCount: 3, display: .underAMinute, locale: english) == "3 · < 1 min")
        #expect(BuildETAFormat.barText(runningCount: 1, display: .minutes(65), locale: english)?.hasPrefix("~1 hr") == true)
    }

    @Test func withoutAnEstimateTheBarKeepsTheDotAloneOrTheCountAlone() {
        #expect(BuildETAFormat.barText(runningCount: 1, display: nil, locale: english) == nil)
        #expect(BuildETAFormat.barText(runningCount: 2, display: nil, locale: english) == "2")
    }

    @Test func theWordsAreFrenchInFrench() {
        let four = "~" + UsageFormat.minutes(4, locale: french)
        #expect(BuildETAFormat.barText(runningCount: 2, display: .minutes(4), locale: french) == "2 · " + four)
        #expect(BuildETAFormat.spoken(.minutes(4), locale: french) == "fin estimée dans 4 minutes")
        #expect(BuildETAFormat.spoken(.underAMinute, locale: french) == "fin estimée dans moins d’une minute")
        #expect(BuildETAFormat.endLine(end: now, display: .minutes(4), locale: french).hasPrefix("Fin estimée vers "))
        #expect(BuildETAFormat.endLine(end: now, display: .minutes(4), locale: french).hasSuffix("(" + four + ")"))
    }

    @Test func voiceOverReadsAnEstimatedEnd() {
        #expect(BuildETAFormat.spoken(.minutes(4), locale: english) == "estimated end in 4 minutes")
        #expect(BuildETAFormat.spoken(.minutes(1), locale: english) == "estimated end in 1 minute")
        #expect(BuildETAFormat.spoken(.underAMinute, locale: english) == "estimated end in less than a minute")
    }

    @Test func theEndLineGivesTheTimeAndTheDuration() {
        let end = now.addingTimeInterval(240)

        #expect(BuildETAFormat.endLine(end: end, display: .minutes(4), locale: english) == "Estimated end around \(UsageFormat.time(end, locale: english)) (~4 min)")
        #expect(BuildETAFormat.endLine(end: end, display: .underAMinute, locale: english).hasSuffix("(< 1 min)"))
    }

    // MARK: - Where it is shown

    @Test func theButtonTitleIsThePercentageUnlessTheTimeLeftSpeaks() {
        #expect(StatusMenuBuilder.buttonTitle(for: nil, timeLeft: "~4 min") == "~4 min")
        #expect(StatusMenuBuilder.buttonTitle(for: nil, isFirstSync: true, timeLeft: "2") == "2")
        #expect(StatusMenuBuilder.buttonTitle(for: nil, isFirstSync: true) == "…")
    }

    @Test func theSettingIsOnByDefaultAndTurnsOff() throws {
        let suite = "BuildETATests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(BuildETAFeature.isOn(defaults))
        defaults.set(false, forKey: BuildETAFeature.settingKey)
        #expect(!BuildETAFeature.isOn(defaults))
        defaults.set(true, forKey: BuildETAFeature.settingKey)
        #expect(BuildETAFeature.isOn(defaults))
    }

    @Test func theSheetOfARunningBuildSaysTheEstimatedEnd() throws {
        let build = running(9, startedMinutesAgo: 6)
        let eta = try #require(BuildETA(run: build, among: history + [build], now: now))

        let model = BuildDetailModel(run: build, product: nil, workflow: nil, actions: [], teamID: nil, now: now, eta: eta, locale: english)

        #expect(model.estimatedEnd == "Estimated end around \(UsageFormat.time(now.addingTimeInterval(240), locale: english)) (~4 min)")
        #expect(model.spokenEstimatedEnd == "estimated end in 4 minutes")
    }

    @Test func theSheetSaysNothingWithoutAnEstimateOrOnceTheBuildEnded() {
        let build = running(9, startedMinutesAgo: 6)
        let done = finished(1, minutes: 5, daysAgo: 1)

        #expect(BuildDetailModel(run: build, product: nil, workflow: nil, actions: [], teamID: nil, now: now).estimatedEnd == nil)
        #expect(BuildDetailModel(run: done, product: nil, workflow: nil, actions: [], teamID: nil, now: now, eta: BuildETA(run: done, among: history, now: now)).estimatedEnd == nil)
    }

    @Test func theMenuHeadsWithTheRunningBuildAndItsAction() {
        let build = running(413, startedMinutesAgo: 6)
        let action = CIBuildAction(
            id: "a1", buildRunID: build.id, name: "Test – iOS", actionType: .test, startedDate: now.addingTimeInterval(-120), finishedDate: nil,
            executionProgress: .running, completionStatus: nil, isRequiredToPass: true
        )
        let done = CIBuildAction(
            id: "a0", buildRunID: build.id, name: "Build", actionType: .build, startedDate: now.addingTimeInterval(-300), finishedDate: now.addingTimeInterval(-120),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true
        )
        let snapshot = BuildSnapshot(
            products: [CIProduct(id: "p", name: "Brioche", productType: "APP", appID: "1", appName: nil, bundleID: nil)],
            runs: history + [build], actionsByRunID: [build.id: [done, action]]
        )

        let lines = RunningBuildLine.lines(in: snapshot, now: now, locale: english)

        #expect(lines.count == 1)
        #expect(lines.first?.title == "Brioche #413")
        #expect(lines.first?.reference == "main")
        #expect(lines.first?.action == "Test – iOS running")
        #expect(lines.first?.endLine?.hasSuffix("(~4 min)") == true)
        let items = StatusMenuBuilder.items(
            for: StatusMenuState(needsAPIKey: false, snapshot: snapshot, isSyncing: false, now: now), actions: StatusMenuActions()
        )
        #expect(items.first?.view != nil)
        #expect(items.dropFirst().first?.isSeparatorItem == true)
    }

    @Test func aQueuedBuildSaysItIsWaitingAndGivesNoEnd() {
        let queued = running(5, startedMinutesAgo: nil, progress: .pending)
        let snapshot = BuildSnapshot(runs: history + [queued])

        let line = RunningBuildLine.lines(in: snapshot, now: now, locale: english).first

        #expect(line?.action == "Waiting to start")
        #expect(line?.endLine == nil)
        #expect(line?.progress == nil)
    }

    @Test func theMenuHasNoRunningBlockWhenNothingRuns() {
        let items = StatusMenuBuilder.items(
            for: StatusMenuState(needsAPIKey: false, snapshot: BuildSnapshot(runs: history), isSyncing: false, now: now), actions: StatusMenuActions()
        )

        #expect(items.allSatisfy { $0.view == nil })
    }
}
