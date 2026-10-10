import Foundation
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

/// Stands in for Notification Center: records what is asked and posted.
actor MockNotificationCenter: NotificationPosting {
    private(set) var status: NotificationAuthorization
    private(set) var posted: [LocalNotification] = []
    private(set) var requestCount = 0
    private let grants: Bool

    init(status: NotificationAuthorization = .notDetermined, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorization() async -> NotificationAuthorization {
        status
    }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        status = grants ? .allowed : .denied
        return grants
    }

    func post(_ notification: LocalNotification) async {
        posted.append(notification)
    }
}

private func run(
    _ number: Int, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded, product: String = "p1",
    createdMinutesAgo: Double = 30, finishedMinutesAgo: Double? = 1, workflowID: String? = "w1", issues: CIIssueCounts? = nil
) -> CIBuildRun {
    let created = now.addingTimeInterval(-createdMinutesAgo * 60)
    return CIBuildRun(
        id: "run-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
        finishedDate: progress == .complete ? finishedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) } : nil,
        executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil,
        workflowID: workflowID, workflowName: "Release", sourceBranchOrTag: "main", issueCounts: issues
    )
}

private func action(
    _ id: String, run runNumber: Int, name: String = "Test - iOS", progress: CIExecutionProgress = .complete,
    startedMinutesAgo: Double, ranFor minutes: Double? = nil
) -> CIBuildAction {
    let started = now.addingTimeInterval(-startedMinutesAgo * 60)
    return CIBuildAction(
        id: id, buildRunID: "run-\(runNumber)", name: name, actionType: .test, startedDate: started,
        finishedDate: minutes.map { started.addingTimeInterval($0 * 60) }, executionProgress: progress,
        completionStatus: progress == .complete ? .succeeded : nil, isRequiredToPass: true
    )
}

private func snapshot(_ runs: [CIBuildRun], actions: [String: [CIBuildAction]] = [:], syncedMinutesAgo: Double? = 0) -> BuildSnapshot {
    BuildSnapshot(
        products: [
            CIProduct(id: "p1", name: "Cumulus", productType: "APP", appID: nil, appName: nil, bundleID: nil),
            CIProduct(id: "p2", name: "Helm", productType: "APP", appID: nil, appName: nil, bundleID: nil),
        ],
        runs: runs, actionsByRunID: actions, lastSuccessfulSync: syncedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
    )
}

struct BuildNotificationPlannerTests {
    private func finished(_ before: BuildSnapshot, _ after: BuildSnapshot, rules: BuildNotificationRules = BuildNotificationRules()) -> [LocalNotification] {
        BuildNotificationPlanner.finished(previous: before, current: after, rules: rules, now: now)
    }

    @Test func aBuildSeenRunningThenSucceededIsAnnounced() throws {
        let notes = finished(snapshot([run(42, progress: .running)], syncedMinutesAgo: 1), snapshot([run(42)]))

        let note = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(note.id == "build-run-42")
        #expect(note.title == "Cumulus #42 succeeded")
        #expect(note.body.hasPrefix("Release · main · "))
        #expect(note.url == URL(string: "cumulus://build/run-42"))
        #expect(note.thread == "p1")
    }

    @Test func aFailedBuildSaysHowManyTestsFailed() throws {
        let failed = run(42, status: .failed, issues: CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 3, warnings: 2))
        let note = try #require(finished(snapshot([run(42, progress: .running)], syncedMinutesAgo: 1), snapshot([failed])).first)

        #expect(note.title == "Cumulus #42 failed")
        #expect(note.body == "3 test failures · Release · main")
    }

    @Test func aBuildThatDidNotCompileSaysHowManyErrors() throws {
        let errored = run(42, status: .errored, issues: CIIssueCounts(analyzerWarnings: 0, errors: 2, testFailures: 0, warnings: 0))
        let note = try #require(finished(snapshot([run(42, progress: .pending)], syncedMinutesAgo: 1), snapshot([errored])).first)

        #expect(note.title == "Cumulus #42 failed")
        #expect(note.body == "2 errors · Release · main")
    }

    @Test func canceledBuildsStayQuietUnlessAskedFor() {
        let before = snapshot([run(42, progress: .running)], syncedMinutesAgo: 1)
        let after = snapshot([run(42, status: .canceled)])

        #expect(finished(before, after).isEmpty)
        #expect(finished(before, after, rules: BuildNotificationRules(canceled: true)).map(\.title) == ["Cumulus #42 was canceled"])
    }

    @Test func eachStateCanBeTurnedOff() {
        let before = snapshot([run(1, progress: .running), run(2, progress: .running)], syncedMinutesAgo: 1)
        let after = snapshot([run(1), run(2, status: .failed)])

        #expect(finished(before, after, rules: BuildNotificationRules(succeeded: false)).map(\.id) == ["build-run-2"])
        #expect(finished(before, after, rules: BuildNotificationRules(failed: false)).map(\.id) == ["build-run-1"])
        #expect(finished(before, after, rules: BuildNotificationRules(succeeded: false, failed: false)).isEmpty)
    }

    @Test func aSkippedBuildIsNeverAnnounced() {
        #expect(finished(snapshot([run(1, progress: .running)], syncedMinutesAgo: 1), snapshot([run(1, status: .skipped)])).isEmpty)
    }

    @Test func nothingIsAnnouncedOnTheFirstLoad() {
        #expect(finished(.empty, snapshot([run(42), run(41, status: .failed)])).isEmpty)
    }

    @Test func aBuildAlreadyFinishedBeforeStaysQuiet() {
        #expect(finished(snapshot([run(42)], syncedMinutesAgo: 1), snapshot([run(42)])).isEmpty)
    }

    @Test func aBuildStartedAndFinishedBetweenTwoSyncsIsAnnounced() {
        let before = snapshot([run(41, createdMinutesAgo: 120, finishedMinutesAgo: 100)], syncedMinutesAgo: 10)

        let quick = run(42, createdMinutesAgo: 8, finishedMinutesAgo: 2)
        #expect(finished(before, snapshot([quick, run(41, createdMinutesAgo: 120, finishedMinutesAgo: 100)])).map(\.id) == ["build-run-42"])

        // An older build that only now enters the list was not watched: it says nothing.
        let old = run(40, createdMinutesAgo: 50, finishedMinutesAgo: 40)
        #expect(finished(before, snapshot([old])).isEmpty)
    }

    @Test func mutedAppsStayQuiet() {
        let before = snapshot([run(1, progress: .running), run(2, progress: .running, product: "p2")], syncedMinutesAgo: 1)
        let after = snapshot([run(1), run(2, product: "p2")])

        let notes = finished(before, after, rules: BuildNotificationRules(mutedProductIDs: ["p1"]))

        #expect(notes.map(\.title) == ["Helm #2 succeeded"])
    }

    @Test func aBuildThatEndedLongAgoIsOldNews() {
        let before = snapshot([run(42, progress: .running, createdMinutesAgo: 300)], syncedMinutesAgo: 240)

        #expect(finished(before, snapshot([run(42, createdMinutesAgo: 300, finishedMinutesAgo: 61)])).isEmpty)
        #expect(finished(before, snapshot([run(42, createdMinutesAgo: 300, finishedMinutesAgo: 59)])).count == 1)
    }

    // MARK: - Stuck builds

    /// Three earlier builds whose test action took 9, 10 and 14 minutes: the usual duration is 10.
    private func history() -> (runs: [CIBuildRun], actions: [String: [CIBuildAction]]) {
        let durations: [Double] = [9, 10, 14]
        let runs = durations.indices.map { run($0 + 1, createdMinutesAgo: Double(600 - $0 * 60), finishedMinutesAgo: Double(500 - $0 * 60)) }
        let actions = Dictionary(uniqueKeysWithValues: durations.enumerated().map { index, minutes in
            ("run-\(index + 1)", [action("a\(index + 1)", run: index + 1, startedMinutesAgo: 600, ranFor: minutes)])
        })
        return (runs, actions)
    }

    private func stuck(
        runningFor minutes: Double, rules: BuildNotificationRules = BuildNotificationRules(), reported: Set<String> = [],
        name: String = "Test - iOS", workflowID: String? = "w1"
    ) -> [StuckBuild] {
        var (runs, actions) = history()
        runs.insert(run(42, progress: .running, createdMinutesAgo: minutes + 5, workflowID: workflowID), at: 0)
        actions["run-42"] = [action("live", run: 42, name: name, progress: .running, startedMinutesAgo: minutes)]
        return BuildNotificationPlanner.stuck(in: snapshot(runs, actions: actions), rules: rules, alreadyReported: reported, now: now)
    }

    @Test func theUsualDurationIsTheMedianOfSuccessfulRuns() {
        let (runs, actions) = history()
        let live = run(42, progress: .running)
        let usual = BuildNotificationPlanner.usualSeconds(
            of: action("live", run: 42, progress: .running, startedMinutesAgo: 1), run: live, in: snapshot([live] + runs, actions: actions)
        )

        #expect(usual == 600)
    }

    @Test func anActionRunningThreeTimesItsUsualDurationIsStuck() throws {
        #expect(stuck(runningFor: 29).isEmpty)

        let found = try #require(stuck(runningFor: 31).first)
        #expect(found.runID == "run-42")
        #expect(found.notification.id == "stuck-run-42")
        #expect(found.notification.title == "Cumulus #42 may be stuck")
        #expect(found.notification.body == "Test - iOS has been running for 31 min, usually 10 min.")
        #expect(found.notification.url == URL(string: "cumulus://build/run-42"))
    }

    @Test func theThresholdIsAdjustable() {
        #expect(stuck(runningFor: 21, rules: BuildNotificationRules(stuckFactor: 2)).count == 1)
        #expect(stuck(runningFor: 45, rules: BuildNotificationRules(stuckFactor: 5)).isEmpty)
        #expect(stuck(runningFor: 51, rules: BuildNotificationRules(stuckFactor: 5)).count == 1)
    }

    @Test func aStuckBuildIsReportedOnceAndOnlyWhenAskedFor() {
        #expect(stuck(runningFor: 60, reported: ["run-42"]).isEmpty)
        #expect(stuck(runningFor: 60, rules: BuildNotificationRules(stuck: false)).isEmpty)
        #expect(stuck(runningFor: 60, rules: BuildNotificationRules(mutedProductIDs: ["p1"])).isEmpty)
    }

    @Test func withoutEnoughHistoryNothingIsCalledStuck() {
        #expect(stuck(runningFor: 600, name: "Archive - iOS").isEmpty)
        #expect(stuck(runningFor: 600, workflowID: "another").isEmpty)
        #expect(stuck(runningFor: 600, workflowID: nil).isEmpty)
    }

    @Test func aShortActionNeedsMoreThanAFewMinutesOver() {
        let durations: [Double] = [1, 1, 1]
        var runs = durations.indices.map { run($0 + 1, createdMinutesAgo: 600, finishedMinutesAgo: 500) }
        var actions = Dictionary(uniqueKeysWithValues: durations.indices.map { ("run-\($0 + 1)", [action("a\($0)", run: $0 + 1, startedMinutesAgo: 600, ranFor: 1)]) })
        runs.insert(run(42, progress: .running), at: 0)

        actions["run-42"] = [action("live", run: 42, progress: .running, startedMinutesAgo: 5)]
        #expect(BuildNotificationPlanner.stuck(in: snapshot(runs, actions: actions), rules: BuildNotificationRules(), alreadyReported: [], now: now).isEmpty)

        actions["run-42"] = [action("live", run: 42, progress: .running, startedMinutesAgo: 12)]
        #expect(BuildNotificationPlanner.stuck(in: snapshot(runs, actions: actions), rules: BuildNotificationRules(), alreadyReported: [], now: now).count == 1)
    }
}

@MainActor
struct NotificationCoordinatorTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "NotificationCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(_ center: MockNotificationCenter) -> NotificationCoordinator {
        NotificationCoordinator(center: center, preferences: NotificationPreferences(defaults: defaults), defaults: defaults, now: { now })
    }

    private let running = snapshot([run(42, progress: .running)], syncedMinutesAgo: 1)
    private let done = snapshot([run(42)])

    @Test func theFirstSyncOfASessionAnnouncesNothingAndAsksNothing() async {
        let center = MockNotificationCenter()
        let coordinator = makeCoordinator(center)

        await coordinator.buildsDidSync(previous: running, current: done)

        #expect(await center.posted.isEmpty)
        #expect(await center.requestCount == 0)
    }

    @Test func permissionIsAskedWhenTheFirstBannerIsDue() async {
        let center = MockNotificationCenter()
        let coordinator = makeCoordinator(center)
        await coordinator.buildsDidSync(previous: .empty, current: running)

        await coordinator.buildsDidSync(previous: running, current: running)
        #expect(await center.requestCount == 0)

        await coordinator.buildsDidSync(previous: running, current: done)
        #expect(await center.requestCount == 1)
        #expect(await center.posted.map(\.title) == ["Cumulus #42 succeeded"])
        #expect(coordinator.authorization == .allowed)
    }

    @Test func aRefusalPostsNothingAndIsNotAskedAgain() async {
        let center = MockNotificationCenter(grants: false)
        let coordinator = makeCoordinator(center)
        await coordinator.buildsDidSync(previous: .empty, current: running)

        await coordinator.buildsDidSync(previous: running, current: done)
        await coordinator.buildsDidSync(previous: running, current: done)

        #expect(await center.posted.isEmpty)
        #expect(await center.requestCount == 1)
        #expect(coordinator.authorization == .denied)
    }

    @Test func aStuckBuildIsReportedOnceEvenAcrossARestart() async {
        var runs = (1...3).map { run($0, createdMinutesAgo: 600, finishedMinutesAgo: 500) }
        var actions = Dictionary(uniqueKeysWithValues: (1...3).map { ("run-\($0)", [action("a\($0)", run: $0, startedMinutesAgo: 600, ranFor: 10)]) })
        runs.insert(run(42, progress: .running), at: 0)
        actions["run-42"] = [action("live", run: 42, progress: .running, startedMinutesAgo: 45)]
        let stuck = snapshot(runs, actions: actions)
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)
        await coordinator.buildsDidSync(previous: .empty, current: stuck)

        await coordinator.buildsDidSync(previous: stuck, current: stuck)
        await coordinator.buildsDidSync(previous: stuck, current: stuck)
        #expect(await center.posted.map(\.id) == ["stuck-run-42"])

        let restarted = makeCoordinator(center)
        await restarted.buildsDidSync(previous: stuck, current: stuck)
        await restarted.buildsDidSync(previous: stuck, current: stuck)
        #expect(await center.posted.count == 1)
    }

    @Test func eachAccountHasItsOwnFirstSyncAndItsBannersNameIt() async {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)
        let personal = NotificationAccount(id: "personal", name: "Personal")
        let work = NotificationAccount(id: "work", name: "Work")
        await coordinator.buildsDidSync(account: personal, previous: .empty, current: running)

        // The other account's first sync says nothing, however long the first one has been watched.
        await coordinator.buildsDidSync(account: work, previous: running, current: done)
        #expect(await center.posted.isEmpty)

        await coordinator.buildsDidSync(account: personal, previous: running, current: done)
        #expect(await center.posted.map(\.subtitle) == ["Personal"])
    }

    @Test func aSingleAccountPutsNoNameOnItsBanners() async {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)
        await coordinator.buildsDidSync(previous: .empty, current: running)

        await coordinator.buildsDidSync(previous: running, current: done)

        #expect(await center.posted.map(\.subtitle) == [nil])
    }

    @Test func aStuckBuildIsNotReportedAgainBecauseAnotherAccountSynced() async {
        var runs = (1...3).map { run($0, createdMinutesAgo: 600, finishedMinutesAgo: 500) }
        var actions = Dictionary(uniqueKeysWithValues: (1...3).map { ("run-\($0)", [action("a\($0)", run: $0, startedMinutesAgo: 600, ranFor: 10)]) })
        runs.insert(run(42, progress: .running), at: 0)
        actions["run-42"] = [action("live", run: 42, progress: .running, startedMinutesAgo: 45)]
        let stuck = snapshot(runs, actions: actions)
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)
        let personal = NotificationAccount(id: "personal", name: "Personal")
        let work = NotificationAccount(id: "work", name: "Work")
        await coordinator.buildsDidSync(account: personal, previous: .empty, current: stuck)
        await coordinator.buildsDidSync(account: personal, previous: stuck, current: stuck)
        #expect(await center.posted.count == 1)

        // The other account knows nothing of build 42: that is no reason to forget it was reported.
        await coordinator.buildsDidSync(account: work, previous: .empty, current: .empty)
        await coordinator.buildsDidSync(account: work, previous: .empty, current: .empty)
        await coordinator.buildsDidSync(account: personal, previous: stuck, current: stuck)

        #expect(await center.posted.count == 1)
    }

    @Test func settingsReadThePermissionWithoutAskingForIt() async {
        let center = MockNotificationCenter(status: .denied)
        let coordinator = makeCoordinator(center)

        await coordinator.refreshAuthorization()

        #expect(coordinator.authorization == .denied)
        #expect(await center.requestCount == 0)
    }

    @Test func preferencesSurviveARestart() {
        let preferences = NotificationPreferences(defaults: defaults)
        #expect(preferences.builds == BuildNotificationRules())

        preferences.builds.succeeded = false
        preferences.builds.canceled = true
        preferences.builds.stuckFactor = 5
        preferences.setMuted(true, productID: "p2")

        let reloaded = NotificationPreferences(defaults: defaults)
        #expect(reloaded.builds == BuildNotificationRules(succeeded: false, canceled: true, stuckFactor: 5, mutedProductIDs: ["p2"]))
        #expect(reloaded.isMuted("p2"))

        reloaded.setMuted(false, productID: "p2")
        #expect(NotificationPreferences(defaults: defaults).builds.mutedProductIDs.isEmpty)
    }
}
