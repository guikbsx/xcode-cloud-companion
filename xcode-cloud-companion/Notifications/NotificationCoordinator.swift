import Foundation
import Observation

/// Decides after each sync what deserves a banner, and asks for the permission the first time one is due:
/// in context, never at launch.
@Observable
final class NotificationCoordinator {
    private(set) var authorization = NotificationAuthorization.notDetermined

    private let center: any NotificationPosting
    private let preferences: NotificationPreferences
    private let defaults: UserDefaults
    private let now: () -> Date
    private let failureWait: Duration
    /// Where the alerts also go; nil sends nothing.
    private let webhook: WebhookService?
    /// The first sync of an account in a session only says where things stand: a build it finds finished ended while nobody was watching.
    private var accountsWithBaseline: Set<String> = []
    private var reportedStuckRunIDs: [String: Set<String>] = [:]
    private var reportedSlowdowns: [String: [String: String]] = [:]
    private var testFlightStates: [String: [String: TestFlightAlertState]] = [:]
    /// The apps (account and product) read at least once in this session: their first read only says where things stand.
    private var testFlightBaselines: Set<String> = []
    private var authorizationRequest: Task<Bool, Never>?
    private var failureBannerTasks: [String: Task<Void, Never>] = [:]

    init(
        center: any NotificationPosting = SystemNotificationCenter(),
        preferences: NotificationPreferences,
        defaults: UserDefaults = .standard,
        failureWait: Duration = FailureBannerFormat.waitLimit,
        webhook: WebhookService? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.center = center
        self.preferences = preferences
        self.defaults = defaults
        self.failureWait = failureWait
        self.webhook = webhook
        self.now = now
    }

    /// One account's sync. `summary` is its usage as of `current`; nil while no plan is set. With `insights` open, a failed
    /// build's banner is posted from a task of its own once its insight is known or the wait is over; nothing else waits for it.
    func buildsDidSync(
        account: NotificationAccount = NotificationAccount(), previous: BuildSnapshot, current: BuildSnapshot, summary: UsageSummary? = nil,
        insights: (any FailureInsightSource)? = nil
    ) async {
        // Read before any state is: nothing here may wait once the account's memory of what was said is in hand.
        let hook = await webhook?.choices(for: account.id)
        let rules = preferences.builds
        let date = now()
        // A stuck build is reported once, even across a restart; it is forgotten when it ends.
        let active = Set(current.runs.filter { $0.executionProgress != .complete }.map(\.id))
        var reported = stuckRunIDs(of: account.id).intersection(active)
        defer { rememberStuck(reported, accountID: account.id) }

        // The first sync of an account only records the slowdowns already there, so they never come as news.
        let slowdowns = SlowdownAlertPlanner.evaluate(snapshot: current, reported: slowdownState(of: account.id))
        defer {
            rememberSlowdowns(slowdowns.reported, accountID: account.id)
        }

        guard accountsWithBaseline.contains(account.id) else {
            accountsWithBaseline.insert(account.id)
            return
        }
        // The webhook's choices are its own: a build the banners skip may still be sent, and the other way round. The
        // guards (muted apps, an hour, the first sync, once for a stuck build) are the ones the banners have.
        var finishedRules = rules
        var stuckRules = rules
        if let hook {
            finishedRules.succeeded = rules.succeeded || hook.succeeded
            finishedRules.failed = rules.failed || hook.failed
            stuckRules.stuck = rules.stuck || hook.stuck
        }
        let finished = BuildNotificationPlanner.finishedBuilds(previous: previous, current: current, rules: finishedRules, now: date)
        let waiting = insights?.isOpen == true ? finished.filter(\.isFailure) : []
        var items: [Outgoing] = []
        for banner in finished where !waiting.contains(banner) {
            items.append(Outgoing(
                notification: banner.notification, isBanner: rules.includes(banner.status),
                event: hook.flatMap { Self.webhookEvent(of: banner.status, in: $0) }, context: Self.context(of: banner.run, in: current)
            ))
        }
        let stuck = BuildNotificationPlanner.stuck(in: current, rules: stuckRules, alreadyReported: reported, now: date)
        reported.formUnion(stuck.map(\.runID))
        for build in stuck {
            items.append(Outgoing(
                notification: build.notification, isBanner: rules.stuck, event: hook?.stuck == true ? .buildStuck : nil,
                context: current.runs.first { $0.id == build.runID }.map { Self.context(of: $0, in: current) } ?? WebhookContext()
            ))
        }
        if rules.slowdown {
            items += slowdowns.fresh.filter { !rules.mutedProductIDs.contains($0.productID) }.map { Outgoing(notification: $0.notification, isBanner: true) }
        }
        if let summary {
            items += usageAlerts(for: summary, accountID: account.id).map { Outgoing(notification: $0, isBanner: true) }
            if hook?.usage == true {
                items += webhookUsageAlerts(for: summary, accountID: account.id).map {
                    Outgoing(notification: $0, isBanner: false, event: .usageAlert, context: WebhookContext(isEstimate: UsageAlertPlanner.isEstimate(summary)))
                }
            }
        }
        // With several accounts, two apps may be named alike: each banner says whose it is.
        for index in items.indices {
            items[index].notification.subtitle = account.name
        }
        webhook?.send(
            items.compactMap { item in item.event.map { WebhookMessage(event: $0, banner: item.notification, account: account.name, context: item.context) } },
            accountID: account.id
        )
        if let insights {
            for banner in waiting {
                let event = hook.flatMap { Self.webhookEvent(of: banner.status, in: $0) }
                let isBanner = rules.includes(banner.status)
                guard isBanner || event != nil else { continue }
                postFailure(
                    banner, account: account, insights: insights, isBanner: isBanner, event: event, context: Self.context(of: banner.run, in: current)
                )
            }
        }
        await deliver(items.filter(\.isBanner).map(\.notification))
    }

    /// One read of an app's TestFlight builds. The first read of an
    /// app in a session says where things stand; what was said is kept for each account, so a banner speaks once, restarts included.
    /// The settings and a muted app silence the banner, not the memory: turned back on, an old build does not come as news.
    func testFlightDidRead(account: NotificationAccount = NotificationAccount(), app: TestFlightApp, builds: [TestFlightBuild]) async {
        let rules = preferences.builds
        var states = testFlightState(of: account.id)
        let alerts = TestFlightAlertPlanner.evaluate(
            app: app, builds: builds, state: states[app.productID] ?? TestFlightAlertState(),
            isBaseline: testFlightBaselines.insert("\(account.id)/\(app.productID)").inserted, now: now()
        )
        states[app.productID] = alerts.state
        rememberTestFlight(states, accountID: account.id)
        guard !rules.mutedProductIDs.contains(app.productID) else { return }
        var banners = (rules.testFlightAvailable ? alerts.available : []) + (rules.testFlightExpiry ? alerts.expiring : [])
        for index in banners.indices {
            banners[index].subtitle = account.name
        }
        await deliver(banners)
    }

    /// Ends when every failed-build banner waiting for its insight has been posted.
    func settleFailureBanners() async {
        while let task = failureBannerTasks.values.first {
            await task.value
        }
    }

    func deliver(_ notifications: [LocalNotification]) async {
        guard !notifications.isEmpty, await ensureAuthorization() else { return }
        for notification in notifications {
            await center.post(notification)
        }
    }

    /// Reads the permission without asking for it, for the Settings tab.
    func refreshAuthorization() async {
        authorization = await center.authorization()
    }

    /// The explicit button of the Settings tab.
    func requestAuthorization() async {
        _ = await ensureAuthorization()
    }

    // MARK: - Private

    /// One thing to say after a sync: a banner, a webhook message, or both. The webhook's wording is the banner's.
    private struct Outgoing {
        var notification: LocalNotification
        var isBanner: Bool
        /// Nil: the webhook is not told.
        var event: WebhookEvent?
        var context = WebhookContext()
    }

    private static func webhookEvent(of status: BuildStatus, in choices: WebhookChoices) -> WebhookEvent? {
        let event: WebhookEvent? = switch status {
        case .succeeded: .buildSucceeded
        case .failed, .errored: .buildFailed
        default: nil
        }
        return event.flatMap { choices.includes($0) ? $0 : nil }
    }

    private static func context(of run: CIBuildRun, in snapshot: BuildSnapshot) -> WebhookContext {
        WebhookContext(app: snapshot.product(id: run.productID)?.displayName, workflow: run.workflowName, build: run.number)
    }

    /// The banner of a failed build goes out once its insight is known, to the notification centre and to the webhook alike.
    private func postFailure(
        _ banner: FinishedBuildBanner, account: NotificationAccount, insights: any FailureInsightSource, isBanner: Bool, event: WebhookEvent?, context: WebhookContext
    ) {
        let id = banner.notification.id
        failureBannerTasks[id] = Task { [failureWait] in
            let record = await insights.record(for: banner.run, within: failureWait)
            let composed = FailureBannerFormat.notification(for: banner, record: record, accountName: account.name)
            if let event {
                webhook?.send([WebhookMessage(event: event, banner: composed, account: account.name, context: context)], accountID: account.id)
            }
            if isBanner {
                await deliver([composed])
            }
            failureBannerTasks[id] = nil
        }
    }

    private func ensureAuthorization() async -> Bool {
        authorization = await center.authorization()
        guard authorization == .notDetermined else { return authorization == .allowed }
        // One prompt at a time, however many syncs pass while it waits for an answer.
        let request = authorizationRequest ?? Task { [center] in await center.requestAuthorization() }
        authorizationRequest = request
        let granted = await request.value
        authorizationRequest = nil
        authorization = granted ? .allowed : .denied
        return granted
    }

    /// What was said in the cycle is kept across restarts, so a threshold speaks once.
    private func usageAlerts(for summary: UsageSummary, accountID: String) -> [LocalNotification] {
        let key = AccountDefaults.key(AccountDefaults.usageAlertState, accountID: accountID)
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageAlertState.self, from: $0) }
        var state = stored ?? UsageAlertState()
        let rules = preferences.usage
        let notifications = UsageAlertPlanner.alerts(for: summary, rules: rules, state: &state, accountID: accountID)
        if state != stored, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
        return notifications
    }

    /// The plan alerts of the webhook, with a state of their own: the banners' choices do not change what the webhook was told.
    private func webhookUsageAlerts(for summary: UsageSummary, accountID: String) -> [LocalNotification] {
        let key = AccountDefaults.key(AccountDefaults.webhookUsageAlertState, accountID: accountID)
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageAlertState.self, from: $0) }
        var state = stored ?? UsageAlertState()
        let notifications = UsageAlertPlanner.alerts(for: summary, rules: UsageAlertRules(), state: &state, accountID: accountID)
        if state != stored, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
        return notifications
    }

    private func stuckRunIDs(of accountID: String) -> Set<String> {
        if let known = reportedStuckRunIDs[accountID] { return known }
        let stored = Set(defaults.stringArray(forKey: AccountDefaults.key(AccountDefaults.reportedStuckRunIDs, accountID: accountID)) ?? [])
        reportedStuckRunIDs[accountID] = stored
        return stored
    }

    private func slowdownState(of accountID: String) -> [String: String] {
        if let known = reportedSlowdowns[accountID] { return known }
        let stored = defaults.data(forKey: AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: accountID))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        reportedSlowdowns[accountID] = stored
        return stored
    }

    private func rememberSlowdowns(_ state: [String: String], accountID: String) {
        guard state != reportedSlowdowns[accountID] else { return }
        reportedSlowdowns[accountID] = state
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: AccountDefaults.key(AccountDefaults.reportedSlowdowns, accountID: accountID))
        }
    }

    private func testFlightState(of accountID: String) -> [String: TestFlightAlertState] {
        if let known = testFlightStates[accountID] { return known }
        let stored = defaults.data(forKey: AccountDefaults.key(AccountDefaults.testFlightAlertState, accountID: accountID))
            .flatMap { try? JSONDecoder().decode([String: TestFlightAlertState].self, from: $0) } ?? [:]
        testFlightStates[accountID] = stored
        return stored
    }

    private func rememberTestFlight(_ state: [String: TestFlightAlertState], accountID: String) {
        guard state != testFlightStates[accountID] else { return }
        testFlightStates[accountID] = state
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: AccountDefaults.key(AccountDefaults.testFlightAlertState, accountID: accountID))
        }
    }

    private func rememberStuck(_ runIDs: Set<String>, accountID: String) {
        guard runIDs != reportedStuckRunIDs[accountID] else { return }
        reportedStuckRunIDs[accountID] = runIDs
        defaults.set(runIDs.sorted(), forKey: AccountDefaults.key(AccountDefaults.reportedStuckRunIDs, accountID: accountID))
    }
}
