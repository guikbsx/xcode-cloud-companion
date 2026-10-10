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
    /// The first sync of an account in a session only says where things stand: a build it finds finished ended while nobody was watching.
    private var accountsWithBaseline: Set<String> = []
    private var reportedStuckRunIDs: [String: Set<String>] = [:]
    private var authorizationRequest: Task<Bool, Never>?

    init(
        center: any NotificationPosting = SystemNotificationCenter(),
        preferences: NotificationPreferences,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.center = center
        self.preferences = preferences
        self.defaults = defaults
        self.now = now
    }

    /// One account's sync. `summary` is its usage as of `current`; nil while no plan is set.
    func buildsDidSync(
        account: NotificationAccount = NotificationAccount(), previous: BuildSnapshot, current: BuildSnapshot, summary: UsageSummary? = nil
    ) async {
        let rules = preferences.builds
        let date = now()
        // A stuck build is reported once, even across a restart; it is forgotten when it ends.
        let active = Set(current.runs.filter { $0.executionProgress != .complete }.map(\.id))
        var reported = stuckRunIDs(of: account.id).intersection(active)
        defer { rememberStuck(reported, accountID: account.id) }

        guard accountsWithBaseline.contains(account.id) else {
            accountsWithBaseline.insert(account.id)
            return
        }
        var notifications = BuildNotificationPlanner.finished(previous: previous, current: current, rules: rules, now: date)
        let stuck = BuildNotificationPlanner.stuck(in: current, rules: rules, alreadyReported: reported, now: date)
        reported.formUnion(stuck.map(\.runID))
        notifications += stuck.map(\.notification)
        if let summary {
            notifications += usageAlerts(for: summary, accountID: account.id)
        }
        // With several accounts, two apps may be named alike: each banner says whose it is.
        for index in notifications.indices {
            notifications[index].subtitle = account.name
        }
        await deliver(notifications)
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
        let notifications = UsageAlertPlanner.alerts(for: summary, rules: preferences.usage, state: &state, accountID: accountID)
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

    private func rememberStuck(_ runIDs: Set<String>, accountID: String) {
        guard runIDs != reportedStuckRunIDs[accountID] else { return }
        reportedStuckRunIDs[accountID] = runIDs
        defaults.set(runIDs.sorted(), forKey: AccountDefaults.key(AccountDefaults.reportedStuckRunIDs, accountID: accountID))
    }
}
