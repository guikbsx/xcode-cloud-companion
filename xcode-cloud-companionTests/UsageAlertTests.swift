import Foundation
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC
private let day: TimeInterval = 24 * 3600

private let firstCycleStart = now.addingTimeInterval(-25 * day)

/// A 25 h plan (1,500 min) on a 30-day cycle, seen `dayOfCycle` days into cycle number `cycle`.
private func summary(
    used: Double, dayOfCycle: Double = 25, estimated: Double = 0, importAge: TimeInterval? = 0, measuring: Bool = false, cycle: Int = 0
) -> UsageSummary {
    let start = firstCycleStart.addingTimeInterval(Double(cycle) * 30 * day)
    let moment = start.addingTimeInterval(dayOfCycle * day)
    var measurement = MeasurementProgress()
    if measuring {
        measurement.totalActions = 4
        measurement.measuredActions = 1
    }
    return UsageSummary(
        plan: UsagePlan(hours: 25, resetAnchor: start), cycle: DateInterval(start: start, duration: 30 * day), now: moment,
        billedMinutes: used - estimated, estimatedMinutes: estimated, estimatedBuildCount: estimated > 0 ? 3 : 0,
        lastImport: importAge.map { moment.addingTimeInterval(-$0) }, daily: [], buildsLast30Days: 0, byApp: [], measurement: measurement
    )
}

struct UsageAlertPlannerTests {
    private func alerts(_ summary: UsageSummary, rules: UsageAlertRules = UsageAlertRules(), state: inout UsageAlertState) -> [LocalNotification] {
        UsageAlertPlanner.alerts(for: summary, rules: rules, state: &state)
    }

    @Test func crossingThreeQuartersThenNineTenthsSpeaksOnceEach() throws {
        var state = UsageAlertState()

        #expect(alerts(summary(used: 1_000), state: &state).isEmpty)

        let first = try #require(alerts(summary(used: 1_130), state: &state).first)
        #expect(first.id == "usage-threshold75")
        #expect(first.title == "75% of your Xcode Cloud plan used")
        #expect(first.body.contains("of 25 h"))
        #expect(first.url == URL(string: "cumulus://overview"))
        #expect(alerts(summary(used: 1_200), state: &state).isEmpty)

        let second = alerts(summary(used: 1_360, dayOfCycle: 28), state: &state)
        #expect(second.map(\.title) == ["90% of your Xcode Cloud plan used"])
        #expect(alerts(summary(used: 1_400, dayOfCycle: 29), state: &state).isEmpty)
        #expect(state.reported == [.threshold75, .threshold90])
    }

    @Test func aPlanAlreadyPastNinetyPercentOnlyGetsThatAlert() {
        var state = UsageAlertState()

        #expect(alerts(summary(used: 1_400, dayOfCycle: 29), state: &state).map(\.id) == ["usage-threshold90"])
        #expect(alerts(summary(used: 1_400, dayOfCycle: 29), state: &state).isEmpty)
    }

    @Test func aNewCycleStartsOver() {
        var state = UsageAlertState()
        _ = alerts(summary(used: 1_400, dayOfCycle: 29), state: &state)

        let nextCycle = summary(used: 1_150, cycle: 1)
        #expect(alerts(nextCycle, state: &state).map(\.id) == ["usage-threshold75"])
        #expect(state.cycleStart == nextCycle.cycle.start)
        #expect(state.reported == [.threshold75])
    }

    @Test func thePaceAlertGivesTheDateThePlanRunsOut() throws {
        var state = UsageAlertState()
        // 600 min in 10 days: 1,800 by the end of the cycle, out after 25 days.
        let fast = summary(used: 600, dayOfCycle: 10)

        let alert = try #require(alerts(fast, state: &state).first)
        #expect(alert.id == "usage-pace")
        #expect(alert.title == "Your Xcode Cloud plan may run out before it resets")
        let exhaustion = try #require(fast.exhaustionDate)
        #expect(alert.body.contains(UsageFormat.day(exhaustion)))
        #expect(alert.url == URL(string: "cumulus://overview"))
        #expect(alerts(fast, state: &state).isEmpty)
    }

    @Test func thePaceSaysNothingBeforeADayOfCycleNorOnceThePlanIsGone() {
        var state = UsageAlertState()

        #expect(alerts(summary(used: 100, dayOfCycle: 0.5), state: &state).isEmpty)
        #expect(alerts(summary(used: 600, dayOfCycle: 20), state: &state).isEmpty)
        #expect(alerts(summary(used: 1_600, dayOfCycle: 20), state: &state).map(\.id) == ["usage-threshold90"])
    }

    @Test func anEstimatedFigureIsCalledAnEstimate() throws {
        var state = UsageAlertState()
        let exact = try #require(alerts(summary(used: 1_130), state: &state).first)
        #expect(!exact.body.contains("Estimated"))
        #expect(!exact.body.contains("~"))

        state = UsageAlertState()
        let partlyEstimated = try #require(alerts(summary(used: 1_130, estimated: 200), state: &state).first)
        #expect(partlyEstimated.body.contains("~"))
        #expect(partlyEstimated.body.contains("Estimated from your builds"))

        for importAge in [nil, 4 * day] as [TimeInterval?] {
            state = UsageAlertState()
            let stale = try #require(alerts(summary(used: 1_130, importAge: importAge), state: &state).first)
            #expect(stale.body.contains("Estimated from your builds"))
        }
    }

    @Test func nothingIsSaidWhileBuildsAreStillBeingMeasured() {
        var state = UsageAlertState()

        #expect(alerts(summary(used: 1_400, measuring: true), state: &state).isEmpty)
        #expect(state == UsageAlertState())
    }

    @Test func eachAlertCanBeTurnedOff() {
        var state = UsageAlertState()
        #expect(alerts(summary(used: 1_130), rules: UsageAlertRules(threshold75: false), state: &state).isEmpty)
        #expect(alerts(summary(used: 1_360, dayOfCycle: 28), rules: UsageAlertRules(threshold75: false), state: &state).map(\.id) == ["usage-threshold90"])

        state = UsageAlertState()
        #expect(alerts(summary(used: 600, dayOfCycle: 10), rules: UsageAlertRules(pace: false), state: &state).isEmpty)

        state = UsageAlertState()
        let none = UsageAlertRules(threshold75: false, threshold90: false, pace: false)
        #expect(alerts(summary(used: 1_450, dayOfCycle: 20), rules: none, state: &state).isEmpty)
    }

    @Test func withTheHigherThresholdOffTheLowerOneStillSpeaksOnce() {
        var state = UsageAlertState()
        let rules = UsageAlertRules(threshold90: false)

        #expect(alerts(summary(used: 1_400, dayOfCycle: 29), rules: rules, state: &state).map(\.id) == ["usage-threshold75"])
        #expect(alerts(summary(used: 1_400, dayOfCycle: 29), rules: rules, state: &state).isEmpty)
    }
}

@MainActor
struct UsageAlertCoordinatorTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "UsageAlertCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(_ center: MockNotificationCenter) -> NotificationCoordinator {
        NotificationCoordinator(center: center, preferences: NotificationPreferences(defaults: defaults), defaults: defaults, now: { now })
    }

    private let snapshot = BuildSnapshot(lastSuccessfulSync: now)

    @Test func noPlanMeansNoAlert() async {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)

        await coordinator.buildsDidSync(previous: snapshot, current: snapshot, summary: nil)
        await coordinator.buildsDidSync(previous: snapshot, current: snapshot, summary: nil)

        #expect(await center.posted.isEmpty)
    }

    @Test func aThresholdAlreadySignalledSurvivesARestart() async {
        let center = MockNotificationCenter(status: .allowed)
        let high = summary(used: 1_130)
        let coordinator = makeCoordinator(center)
        await coordinator.buildsDidSync(previous: snapshot, current: snapshot, summary: high)
        #expect(await center.posted.isEmpty)

        await coordinator.buildsDidSync(previous: snapshot, current: snapshot, summary: high)
        await coordinator.buildsDidSync(previous: snapshot, current: snapshot, summary: high)
        #expect(await center.posted.map(\.id) == ["usage-threshold75-default"])

        let restarted = makeCoordinator(center)
        await restarted.buildsDidSync(previous: snapshot, current: snapshot, summary: high)
        await restarted.buildsDidSync(previous: snapshot, current: snapshot, summary: high)
        #expect(await center.posted.count == 1)

        let nextCycle = summary(used: 1_130, cycle: 1)
        await restarted.buildsDidSync(previous: snapshot, current: snapshot, summary: nextCycle)
        #expect(await center.posted.map(\.id) == ["usage-threshold75-default", "usage-threshold75-default"])
    }

    @Test func eachAccountIsWarnedAboutItsOwnPlanAndTheClickOpensItsOverview() async throws {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)
        let personal = NotificationAccount(id: "personal", name: "Personal")
        let work = NotificationAccount(id: "work", name: "Work")
        let high = summary(used: 1_130)
        for account in [personal, work] {
            await coordinator.buildsDidSync(account: account, previous: snapshot, current: snapshot, summary: nil)
        }

        await coordinator.buildsDidSync(account: personal, previous: snapshot, current: snapshot, summary: high)
        // One account past its threshold says nothing of the other: it is warned in its turn, once.
        await coordinator.buildsDidSync(account: work, previous: snapshot, current: snapshot, summary: high)
        await coordinator.buildsDidSync(account: work, previous: snapshot, current: snapshot, summary: high)

        let posted = await center.posted
        #expect(posted.map(\.id) == ["usage-threshold75-personal", "usage-threshold75-work"])
        #expect(posted.map(\.subtitle) == ["Personal", "Work"])
        let url = try #require(posted.last?.url)
        #expect(CumulusURL.destination(of: url) == .overview(accountID: "work"))
    }

    @Test func planAlertPreferencesSurviveARestart() {
        let preferences = NotificationPreferences(defaults: defaults)
        #expect(preferences.usage == UsageAlertRules())

        preferences.usage.threshold75 = false
        preferences.usage.pace = false

        #expect(NotificationPreferences(defaults: defaults).usage == UsageAlertRules(threshold75: false, threshold90: true, pace: false))
    }

    @Test func theOverviewAddressOpensTheOverview() throws {
        let navigation = NavigationModel()
        navigation.showBuild("abc")

        #expect(navigation.open(try #require(CumulusURL.overview)))
        #expect(navigation.sidebarSelection == .overview)
        #expect(navigation.selectedBuildID == nil)
        #expect(CumulusURL.destination(of: try #require(URL(string: "cumulus://overview/extra"))) == nil)
    }
}
