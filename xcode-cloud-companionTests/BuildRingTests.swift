import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildRingTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")

    // MARK: Fixtures

    /// An action that started `start` seconds from now (negative: before) and ran `seconds`; no end when `seconds` is nil.
    private func action(
        _ run: String, _ name: String?, _ type: CIActionType, start: Double?, seconds: Double?,
        progress: CIExecutionProgress = .complete, completion: CICompletionStatus? = .succeeded, id: String? = nil
    ) -> CIBuildAction {
        let started = start.map { now.addingTimeInterval($0) }
        return CIBuildAction(
            id: id ?? "\(run)-\(name ?? "none")-\(Int(start ?? 0))", buildRunID: run, name: name, actionType: type, startedDate: started,
            finishedDate: seconds.flatMap { seconds in started.map { $0.addingTimeInterval(seconds) } }, executionProgress: progress,
            completionStatus: completion, isRequiredToPass: nil
        )
    }

    private func run(
        _ id: String, progress: CIExecutionProgress = .complete, completion: CICompletionStatus? = nil, startedAgo: Double? = nil,
        workflow: String? = "wf", seconds: Double? = nil
    ) -> CIBuildRun {
        let started = startedAgo.map { now.addingTimeInterval(-$0) }
        return CIBuildRun(
            id: id, productID: "p", number: 7, createdDate: now.addingTimeInterval(-(startedAgo ?? 0) - 20), startedDate: started,
            finishedDate: seconds.flatMap { seconds in started.map { $0.addingTimeInterval(seconds) } }, executionProgress: progress,
            completionStatus: completion, startReason: nil, workflowID: workflow, workflowName: "Release", sourceBranchOrTag: "main"
        )
    }

    /// `count` succeeded builds of the workflow: Build 120 s, Test – iOS 220 s, Archive 60 s.
    private func history(_ count: Int) -> (runs: [CIBuildRun], actions: [String: [CIBuildAction]]) {
        var runs: [CIBuildRun] = []
        var actions: [String: [CIBuildAction]] = [:]
        for index in stride(from: 1, through: count, by: 1) {
            let id = "h\(index)"
            let begin = -86_400.0 * Double(index)
            runs.append(CIBuildRun(
                id: id, productID: "p", number: index, createdDate: now.addingTimeInterval(begin), startedDate: now.addingTimeInterval(begin),
                finishedDate: now.addingTimeInterval(begin + 400), executionProgress: .complete, completionStatus: .succeeded,
                startReason: nil, workflowID: "wf", workflowName: "Release", sourceBranchOrTag: "main"
            ))
            actions[id] = [
                action(id, "Build", .build, start: begin, seconds: 120),
                action(id, "Test – iOS", .test, start: begin + 120, seconds: 220),
                action(id, "Archive", .archive, start: begin + 340, seconds: 60),
            ]
        }
        return (runs, actions)
    }

    private func snapshot(_ run: CIBuildRun, _ actions: [CIBuildAction], history count: Int = 3) -> BuildSnapshot {
        let past = history(count)
        var byRun = past.actions
        byRun[run.id] = actions
        return BuildSnapshot(runs: past.runs + [run], actionsByRunID: byRun)
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func ring(_ run: CIBuildRun, _ snapshot: BuildSnapshot, locale: Locale? = nil) -> BuildRing {
        BuildRing(run: run, in: snapshot, now: now, locale: locale ?? english)
    }

    private func turn(of ring: BuildRing) -> Double {
        ring.arcs.reduce(0) { $0 + $1.length } + Double(ring.arcs.count) * BuildRing.gap
    }

    private func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    // MARK: Finished builds

    @Test func aSucceededBuildHasOneArcPerActionAsLongAsItsTime() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, seconds: 420)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 240),
            action("r", "Archive", .archive, start: -640, seconds: 60),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.state == .finished)
        #expect(result.status == .succeeded)
        #expect(result.arcs.count == 3)
        let usable = 1 - 3 * BuildRing.gap
        #expect(near(result.arcs[0].length, 120.0 / 420 * usable))
        #expect(near(result.arcs[1].length, 240.0 / 420 * usable))
        #expect(near(result.arcs[2].length, 60.0 / 420 * usable))
        #expect(result.arcs.allSatisfy { $0.status == .succeeded && $0.marker == .none && $0.mergedCount == 1 && !$0.isEstimated })
        #expect(result.arcs.allSatisfy { near($0.solidLength, $0.length) })
        #expect(result.head == nil && result.overflow == nil && result.nextChange == nil)
    }

    @Test func arcsAndGapsMakeAFullTurnAndFollowEachOther() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, seconds: 420)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 240),
            action("r", "Archive", .archive, start: -640, seconds: 60),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(near(turn(of: result), 1))
        #expect(near(result.arcs[0].start, 0))
        for (previous, next) in zip(result.arcs, result.arcs.dropFirst()) {
            #expect(near(next.start, previous.end + BuildRing.gap))
        }
    }

    @Test func aFailedActionIsRedAndMarkedWithACross() throws {
        let build = run("r", completion: .failed, startedAgo: 1_000, seconds: 400)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 220, completion: .failed),
            action("r", "Archive", .archive, start: -660, seconds: nil, progress: .pending, completion: nil),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.status == .failed)
        #expect(result.arcs.map(\.status) == [.succeeded, .failed, .skipped])
        #expect(result.arcs.map(\.marker) == [.none, .cross, .dashed])
    }

    @Test func anErrorOnApplesSideIsASlitAndWhatFollowsDidNotRun() throws {
        let build = run("r", completion: .errored, startedAgo: 1_000, seconds: 300)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 80, completion: .errored),
            action("r", "Archive", .archive, start: nil, seconds: nil, progress: .pending, completion: nil),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.arcs.map(\.marker) == [.none, .slit, .dashed])
        #expect(result.arcs[1].status == .errored)
        #expect(result.arcs[2].solidLength == 0)
        #expect(near(result.arcs[2].length, 60.0 / 260 * (1 - 3 * BuildRing.gap)), "an action that did not run takes its usual duration")
        #expect(result.arcs[2].isEstimated == false)
        #expect(near(turn(of: result), 1))
    }

    @Test func aCanceledBuildHasAShortGreyArcAndTheRestDashed() throws {
        let build = run("r", completion: .canceled, startedAgo: 1_000, seconds: 150)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 30, completion: .canceled),
            action("r", "Test – iOS", .test, start: nil, seconds: nil, progress: .complete, completion: .skipped),
            action("r", "Archive", .archive, start: nil, seconds: nil, progress: .complete, completion: .canceled),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.status == .canceled)
        #expect(result.arcs.map(\.status) == [.canceled, .skipped, .canceled])
        #expect(result.arcs.map(\.marker) == [.none, .dashed, .dashed], "the canceled action ran, what never started did not")
        #expect(near(result.arcs[0].solidLength, result.arcs[0].length), "the canceled action did run")
        #expect(result.arcs[1].solidLength == 0 && result.arcs[2].solidLength == 0)
        #expect(result.arcs[0].length < result.arcs[1].length)
    }

    @Test func arcsFollowTheOrderOfTheFriezeNotTheOrderOfTheList() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, seconds: 420)
        let actions = [
            action("r", "Archive", .archive, start: -640, seconds: 60),
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 240),
        ]
        let result = ring(build, snapshot(build, actions))
        let usable = 1 - 3 * BuildRing.gap

        #expect(near(result.arcs[0].length, 120.0 / 420 * usable))
        #expect(near(result.arcs[2].length, 60.0 / 420 * usable))
        #expect(result.spokenDescription.hasPrefix("Build 2 min, Test – iOS 4 min, Archive 1 min"))
    }

    @Test func aSkippedBuildHasNoArcs() throws {
        let build = run("r", completion: .skipped)
        let result = ring(build, snapshot(build, []))

        #expect(result.state == .skipped)
        #expect(result.arcs.isEmpty)
        #expect(result.status == .skipped)
    }

    @Test func actionsWithTheSameNameAreAddedUp() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, seconds: 560)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120),
            action("r", "Test – iOS", .test, start: -880, seconds: 100, completion: .failed, id: "first"),
            action("r", "Test – iOS", .test, start: -700, seconds: 140, id: "again"),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.arcs.count == 2)
        #expect(near(result.arcs[1].length, 240.0 / 360 * (1 - 2 * BuildRing.gap)))
        #expect(result.arcs[1].status == .succeeded, "the last attempt says how the action ended")
        #expect(result.arcs[1].marker == .none)
        #expect(result.spokenDescription == "Build 2 min, Test – iOS 4 min")
    }

    @Test func shortArcsMergeIntoTheirNeighbourAndTheWorstStateWins() throws {
        let build = run("r", completion: .failed, startedAgo: 2_000, seconds: 915)
        let actions = [
            action("r", "A", .build, start: -2_000, seconds: 300),
            action("r", "B", .analyze, start: -1_700, seconds: 5),
            action("r", "C", .analyze, start: -1_695, seconds: 5, completion: .failed),
            action("r", "D", .analyze, start: -1_690, seconds: 5),
            action("r", "E", .test, start: -1_685, seconds: 300),
            action("r", "F", .archive, start: -1_385, seconds: 300),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.arcs.count == 4)
        #expect(result.arcs.map(\.mergedCount) == [1, 3, 1, 1])
        #expect(result.arcs[1].status == .failed)
        #expect(result.arcs[1].marker == .cross)
        #expect(result.arcs.allSatisfy { $0.length >= BuildRing.minimumArc })
        #expect(near(turn(of: result), 1))
        #expect(result.spokenDescription.contains("C 5 sec failed"), "VoiceOver still speaks every action")
    }

    @Test func aBuildWithoutHistoryStillGetsItsRingFromItsOwnActions() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, workflow: nil, seconds: 180)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 60),
            action("r", "Test", .test, start: -940, seconds: 120),
        ]
        let result = ring(build, snapshot(build, actions, history: 0))

        #expect(result.state == .finished)
        #expect(result.arcs.count == 2)
    }

    // MARK: Without actions, queued

    @Test func aBuildWhoseActionsAreNotKnownKeepsOnlyItsState() throws {
        let failed = run("old", completion: .failed, startedAgo: 5_000, seconds: 300)
        let result = ring(failed, BuildSnapshot(runs: []))

        #expect(result.state == .unknown)
        #expect(result.status == .failed)
        #expect(result.arcs.isEmpty)
        #expect(result.spokenDescription == "Failed")
    }

    @Test func aRunningBuildWhoseActionsAreNotReadYetIsUnknownToo() throws {
        let build = run("r", progress: .running, startedAgo: 30)
        let result = ring(build, BuildSnapshot(runs: [build]))

        #expect(result.state == .unknown)
        #expect(result.status == .running)
        #expect(result.arcs.isEmpty && result.head == nil)
    }

    @Test func aQueuedBuildHasNoArcs() throws {
        let build = run("r", progress: .pending)
        let result = ring(build, snapshot(build, []))

        #expect(result.state == .queued)
        #expect(result.arcs.isEmpty)
        #expect(result.head == nil && result.nextChange == nil)
        #expect(result.spokenDescription == "Waiting to start")
    }

    // MARK: Running builds

    private func runningActions(testElapsed: Double) -> [CIBuildAction] {
        [
            action("r", "Build", .build, start: -(120 + testElapsed), seconds: 120),
            action("r", "Test – iOS", .test, start: -testElapsed, seconds: nil, progress: .running, completion: nil),
            action("r", "Archive", .archive, start: nil, seconds: nil, progress: .pending, completion: nil),
        ]
    }

    @Test func aRunningBuildIsFullUpToNowThenPaleThenEmpty() throws {
        let build = run("r", progress: .running, startedAgo: 220)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 100)))

        #expect(result.state == .running)
        let usable = 1 - 3 * BuildRing.gap
        #expect(result.arcs.count == 3)
        #expect(near(result.arcs[0].length, 120.0 / 400 * usable))
        #expect(near(result.arcs[1].length, 220.0 / 400 * usable))
        #expect(near(result.arcs[2].length, 60.0 / 400 * usable))
        #expect(near(result.arcs[0].solidLength, result.arcs[0].length))
        #expect(near(result.arcs[1].solidLength, 100.0 / 400 * usable))
        #expect(result.arcs[1].isEstimated)
        #expect(result.arcs[2].solidLength == 0 && result.arcs[2].isEstimated)
        #expect(result.arcs.map(\.status) == [.succeeded, .running, .running])
        #expect(near(result.head, result.arcs[1].start + 100.0 / 400 * usable))
        #expect(result.overflow == nil)
        #expect(near(turn(of: result), 1))
    }

    @Test func aRunningBuildWithTheSecondActionOnlyJustFinishedHasItsHeadAtTheNextArc() throws {
        let build = run("r", progress: .running, startedAgo: 345)
        let actions = [
            action("r", "Build", .build, start: -345, seconds: 120),
            action("r", "Test – iOS", .test, start: -225, seconds: 220),
            action("r", "Archive", .archive, start: nil, seconds: nil, progress: .pending, completion: nil),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.state == .running)
        #expect(near(result.head, result.arcs[1].end))
    }

    @Test func aBuildThatOutlastsItsUsualDurationIsFullAndLapsOver() throws {
        let build = run("r", progress: .running, startedAgo: 420)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 300)))

        #expect(result.state == .overrun)
        #expect(near(result.arcs[1].solidLength, result.arcs[1].length))
        #expect(result.arcs[1].isEstimated == false)
        #expect(near(result.head, result.arcs[1].end))
        #expect(near(result.overflow, 80.0 / 400))
    }

    @Test func anOverrunWithActionsStillToComeKeepsTheirEmptyArcsAfterTheHead() throws {
        let build = run("r", progress: .running, startedAgo: 420)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 300)))

        #expect(result.arcs.count == 3)
        #expect(result.arcs[2].solidLength == 0 && result.arcs[2].isEstimated)
        #expect(near(result.head, result.arcs[1].end))
    }

    @Test func theSecondLapNeverGoesBeyondOneTurn() throws {
        let build = run("r", progress: .running, startedAgo: 9_000)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 8_880)))

        #expect(result.state == .overrun)
        #expect(result.overflow == 1)
    }

    @Test func withoutEnoughHistoryTheArcsFollowTheElapsedTimeAlone() throws {
        let build = run("r", progress: .running, startedAgo: 220)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 100), history: 2))

        #expect(result.state == .unestimated)
        #expect(result.arcs.count == 2, "what has not begun is not drawn")
        let usable = 1 - 2 * BuildRing.gap
        #expect(near(result.arcs[0].length, 120.0 / BuildRing.unestimatedTurn * usable))
        #expect(near(result.arcs[1].length, 100.0 / BuildRing.unestimatedTurn * usable))
        #expect(result.arcs.allSatisfy { !$0.isEstimated && near($0.solidLength, $0.length) })
        #expect(near(result.head, result.arcs[1].end))
        #expect(result.overflow == nil)
    }

    @Test func aRunningBuildWithoutWorkflowHasNoEstimateEither() throws {
        let build = run("r", progress: .running, startedAgo: 220, workflow: nil)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 100)))

        #expect(result.state == .unestimated)
    }

    @Test func aLongUnestimatedBuildNeverDrawsMoreThanATurn() throws {
        let build = run("r", progress: .running, startedAgo: 4_000, workflow: nil)
        let actions = [action("r", "Test – iOS", .test, start: -4_000, seconds: nil, progress: .running, completion: nil)]
        let result = ring(build, snapshot(build, actions))

        #expect(result.state == .unestimated)
        #expect(result.arcs.count == 1)
        #expect(near(result.arcs[0].length, 1 - BuildRing.gap))
    }

    // MARK: Next change

    @Test func aRunningRingChangesWithinTheMinuteAndNeverBeforeTenSeconds() throws {
        let build = run("r", progress: .running, startedAgo: 220)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 100)))

        let wait = try #require(result.nextChange).timeIntervalSince(now)
        #expect(wait >= BuildRing.shortestRedraw && wait <= BuildRing.longestRedraw)
    }

    @Test func aRingChangesWhenTheCurrentActionReachesItsUsualDuration() throws {
        let build = run("r", progress: .running, startedAgo: 340)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 215)))

        let wait = try #require(result.nextChange).timeIntervalSince(now)
        #expect(abs(wait - 5.1) < 0.01)
    }

    @Test func aRingThatDoesNotMoveHasNoNextChange() throws {
        let build = run("r", completion: .succeeded, startedAgo: 1_000, seconds: 120)
        let done = ring(build, snapshot(build, [action("r", "Build", .build, start: -1_000, seconds: 120)]))

        #expect(done.nextChange == nil)
    }

    // MARK: Words

    @Test func aFinishedBuildIsSpokenActionByAction() throws {
        let build = run("r", completion: .failed, startedAgo: 1_000, seconds: 252)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 121),
            action("r", "Test – iOS", .test, start: -879, seconds: 220, completion: .failed),
            action("r", "Test – macOS", .test, start: -879, seconds: 31),
        ]
        let result = ring(build, snapshot(build, actions))

        #expect(result.spokenDescription == "Build 2 min 1 sec, Test – iOS 3 min 40 sec failed, Test – macOS 31 sec")
        #expect(plain(ring(build, snapshot(build, actions), locale: french).spokenDescription) == "Build 2 min 1 s, Test – iOS 3 min 40 s en échec, Test – macOS 31 s")
    }

    @Test func anActionThatDidNotRunIsSaidSo() throws {
        let build = run("r", completion: .errored, startedAgo: 1_000, seconds: 120)
        let actions = [
            action("r", "Build", .build, start: -1_000, seconds: 120, completion: .errored),
            action("r", "Test – iOS", .test, start: nil, seconds: nil, progress: .pending, completion: nil),
        ]

        #expect(ring(build, snapshot(build, actions)).spokenDescription == "Build 2 min errored, Test – iOS not run")
        #expect(plain(ring(build, snapshot(build, actions), locale: french).spokenDescription) == "Build 2 min en erreur, Test – iOS non lancée")
    }

    @Test func aRunningBuildIsSpokenByItsCurrentActionAndItsEstimatedEnd() throws {
        let build = run("r", progress: .running, startedAgo: 220)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 100)))

        #expect(result.spokenDescription == "Test – iOS running for 1 min 40 sec, estimated end in 3 minutes")
        #expect(plain(ring(build, snapshot(build, runningActions(testElapsed: 100)), locale: french).spokenDescription)
            == "Test – iOS en cours depuis 1 min 40 s, fin estimée dans 3 minutes")
    }

    @Test func anOverrunningBuildIsSpokenAsLongerThanUsual() throws {
        let build = run("r", progress: .running, startedAgo: 420)
        let result = ring(build, snapshot(build, runningActions(testElapsed: 300)))

        #expect(result.spokenDescription == "Test – iOS running for 5 min, longer than usual")
    }

    @Test func aBuildThatIsOnlyKnownByItsStateIsSpokenWithIt() throws {
        let build = run("r", progress: .running, startedAgo: 30)

        #expect(ring(build, BuildSnapshot(runs: [build])).spokenDescription == "Running")
        #expect(ring(build, BuildSnapshot(runs: [build]), locale: french).spokenDescription == "En cours")
    }
}
