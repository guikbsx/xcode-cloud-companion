import Foundation
import Testing
@testable import XcodeCloudCompanion

private let start = Date(timeIntervalSince1970: 1_791_000_000)

private func run(_ index: Int, minutes: Double, workflowID: String = "w", product: String = "p1") -> CIBuildRun {
    let created = start.addingTimeInterval(Double(index) * 3600)
    return CIBuildRun(
        id: "\(workflowID)-\(index)", productID: product, number: 100 + index, createdDate: created, startedDate: created,
        finishedDate: created.addingTimeInterval(minutes * 60), executionProgress: .complete, completionStatus: .succeeded, startReason: nil,
        workflowID: workflowID, workflowName: "Release", sourceBranchOrTag: "main"
    )
}

/// `count` builds of the workflow, the ones from index `slowFrom` on taking 18 minutes instead of 13.
private func builds(_ count: Int, slowFrom: Int, workflowID: String = "w", product: String = "p1") -> [CIBuildRun] {
    (0..<count).map { run($0, minutes: $0 < slowFrom ? 13 : 18, workflowID: workflowID, product: product) }
}

private func snapshot(_ runs: [CIBuildRun]) -> BuildSnapshot {
    BuildSnapshot(
        products: [
            CIProduct(id: "p1", name: "Brioche", productType: "APP", appID: nil, appName: nil, bundleID: nil),
            CIProduct(id: "p2", name: "Helm", productType: "APP", appID: nil, appName: nil, bundleID: nil),
        ],
        runs: runs, lastSuccessfulSync: start.addingTimeInterval(100 * 3600)
    )
}

struct SlowdownAlertPlannerTests {
    @Test func aSlowdownSpeaksOnceByTheBuildThatStartsIt() throws {
        let before = SlowdownAlertPlanner.evaluate(snapshot: snapshot(builds(29, slowFrom: 25)), reported: [:])
        #expect(before.fresh.isEmpty && before.reported.isEmpty, "four slow builds are not a level yet")

        let first = SlowdownAlertPlanner.evaluate(snapshot: snapshot(builds(30, slowFrom: 25)), reported: [:])
        let banner = try #require(first.fresh.first)
        #expect(first.fresh.count == 1 && banner.runID == "w-25" && banner.workflowID == "w" && banner.productID == "p1")
        #expect(banner.notification.id == "slowdown-w-25" && banner.notification.thread == "p1")
        #expect(banner.notification.title == "Brioche · Release slowed down by 38%")
        #expect(banner.notification.url == CumulusURL.build(id: "w-25"))
        #expect(first.reported == ["w": "w-25"])

        let again = SlowdownAlertPlanner.evaluate(snapshot: snapshot(builds(32, slowFrom: 25)), reported: first.reported)
        #expect(again.fresh.isEmpty && again.reported == first.reported, "still there, not news")
    }

    @Test func aBreakFoundEarlierWithMoreBuildsIsTheSameSlowdown() {
        let said = ["w": "w-26"]

        let result = SlowdownAlertPlanner.evaluate(snapshot: snapshot(builds(34, slowFrom: 25)), reported: said)

        #expect(result.fresh.isEmpty && result.reported == said)
    }

    @Test func aLaterBreakIsAnotherSlowdown() {
        // The workflow went from 13 to 24 minutes at build 30, long after the slowdown that was said at build 14.
        let runs = (0..<36).map { run($0, minutes: $0 < 30 ? 13 : 24) }

        let result = SlowdownAlertPlanner.evaluate(snapshot: snapshot(runs), reported: ["w": "w-14"])

        #expect(result.fresh.map(\.runID) == ["w-30"] && result.reported == ["w": "w-30"])
    }

    @Test func workflowsAreJudgedEachOnItsOwnAndForgottenWhenGone() {
        let runs = builds(30, slowFrom: 25, workflowID: "a") + builds(30, slowFrom: 30, workflowID: "b", product: "p2")

        let result = SlowdownAlertPlanner.evaluate(snapshot: snapshot(runs), reported: ["gone": "gone-3", "b": "b-1"])

        #expect(result.fresh.map(\.workflowID) == ["a"])
        #expect(result.reported == ["a": "a-25", "b": "b-1"])
    }
}

@MainActor
struct SlowdownAlertCoordinatorTests {
    private let defaults: UserDefaults
    private let moment = start.addingTimeInterval(100 * 3600)

    init() {
        let suiteName = "SlowdownAlertCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func coordinator(_ center: MockNotificationCenter, pro: ProStore? = nil) -> NotificationCoordinator {
        NotificationCoordinator(center: center, preferences: NotificationPreferences(defaults: defaults), defaults: defaults, pro: pro, now: { moment })
    }

    private var lifetime: ProStore { ProStore(source: StubProSource(), forced: .lifetime(since: start)) }

    @Test func theBannerComesOnceAndNeverOnTheFirstSyncOfAnAccount() async {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = coordinator(center, pro: lifetime)
        let quiet = snapshot(builds(29, slowFrom: 25))
        let slow = snapshot(builds(30, slowFrom: 25))

        await coordinator.buildsDidSync(previous: slow, current: slow)
        #expect(await center.posted.isEmpty, "the slowdown was already there when the account was first read")
        await coordinator.buildsDidSync(previous: slow, current: slow)
        #expect(await center.posted.isEmpty)

        let other = NotificationAccount(id: "second", name: "Work")
        await coordinator.buildsDidSync(account: other, previous: quiet, current: quiet)
        await coordinator.buildsDidSync(account: other, previous: quiet, current: slow)
        await coordinator.buildsDidSync(account: other, previous: slow, current: slow)
        let posted = await center.posted
        #expect(posted.map(\.id) == ["slowdown-w-25"] && posted.first?.subtitle == "Work", "each account on its own, named when there are several")
    }

    @Test func whatWasSaidSurvivesARestart() async {
        let center = MockNotificationCenter(status: .allowed)
        let quiet = snapshot(builds(29, slowFrom: 25))
        let slow = snapshot(builds(30, slowFrom: 25))
        let first = coordinator(center, pro: lifetime)
        await first.buildsDidSync(previous: quiet, current: quiet)
        await first.buildsDidSync(previous: quiet, current: slow)
        #expect(await center.posted.count == 1)

        let restarted = coordinator(center, pro: lifetime)
        await restarted.buildsDidSync(previous: slow, current: slow)
        await restarted.buildsDidSync(previous: slow, current: slow)

        #expect(await center.posted.count == 1)
        let key = AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: AccountRegistry.firstAccountID)
        #expect(defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } == ["w": "w-25"])
    }

    @Test func withoutProNothingIsSentOrRemembered() async {
        let center = MockNotificationCenter(status: .allowed)
        let free = ProStore(source: StubProSource(), forced: .free)
        let coordinator = coordinator(center, pro: free)
        let quiet = snapshot(builds(29, slowFrom: 25))
        let slow = snapshot(builds(30, slowFrom: 25))

        await coordinator.buildsDidSync(previous: quiet, current: quiet)
        await coordinator.buildsDidSync(previous: quiet, current: slow)

        #expect(await center.posted.isEmpty)
        let key = AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: AccountRegistry.firstAccountID)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func theSettingAndAMutedAppSilenceTheBannerButNotTheMemory() async {
        let center = MockNotificationCenter(status: .allowed)
        let preferences = NotificationPreferences(defaults: defaults)
        let coordinator = NotificationCoordinator(center: center, preferences: preferences, defaults: defaults, pro: lifetime, now: { moment })
        let quiet = snapshot(builds(29, slowFrom: 25))
        let slow = snapshot(builds(30, slowFrom: 25))
        #expect(preferences.builds.slowdown, "on by default")

        preferences.builds.slowdown = false
        await coordinator.buildsDidSync(previous: quiet, current: quiet)
        await coordinator.buildsDidSync(previous: quiet, current: slow)
        preferences.builds.slowdown = true
        await coordinator.buildsDidSync(previous: slow, current: slow)
        #expect(await center.posted.isEmpty, "turned back on, an old slowdown does not come as news")

        let muted = MockNotificationCenter(status: .allowed)
        preferences.builds.mutedProductIDs = ["p1"]
        let silent = NotificationCoordinator(center: muted, preferences: preferences, defaults: defaults, pro: lifetime, now: { moment })
        let second = NotificationAccount(id: "other", name: nil)
        await silent.buildsDidSync(account: second, previous: quiet, current: quiet)
        await silent.buildsDidSync(account: second, previous: quiet, current: slow)
        #expect(await muted.posted.isEmpty)
    }

    @Test func theSettingIsKeptAcrossLaunchesAndEachAccountHasItsOwnMemory() {
        let preferences = NotificationPreferences(defaults: defaults)
        preferences.builds.slowdown = false
        #expect(!NotificationPreferences(defaults: defaults).builds.slowdown)
        #expect(AccountDefaults.names.contains(AccountDefaults.reportedSlowdowns))

        defaults.set(Data("{}".utf8), forKey: AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: "gone"))
        AccountDefaults.removeAll(accountID: "gone", from: defaults)
        #expect(defaults.data(forKey: AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: "gone")) == nil)
    }
}
