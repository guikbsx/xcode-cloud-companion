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
    /// The first sync of a session only says where things stand: a build it finds finished ended while nobody was watching.
    private var hasBaseline = false
    private var reportedStuckRunIDs: Set<String>
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
        reportedStuckRunIDs = Set(defaults.stringArray(forKey: Keys.reportedStuckRunIDs) ?? [])
    }

    /// `summary` is the usage as of `current`; nil while no plan is set.
    func buildsDidSync(previous: BuildSnapshot, current: BuildSnapshot, summary: UsageSummary? = nil) async {
        let rules = preferences.builds
        let date = now()
        // A stuck build is reported once, even across a restart; it is forgotten when it ends.
        let active = Set(current.runs.filter { $0.executionProgress != .complete }.map(\.id))
        var reported = reportedStuckRunIDs.intersection(active)
        defer { rememberStuck(reported) }

        guard hasBaseline else {
            hasBaseline = true
            return
        }
        var notifications = BuildNotificationPlanner.finished(previous: previous, current: current, rules: rules, now: date)
        let stuck = BuildNotificationPlanner.stuck(in: current, rules: rules, alreadyReported: reported, now: date)
        reported.formUnion(stuck.map(\.runID))
        notifications += stuck.map(\.notification)
        if let summary {
            notifications += usageAlerts(for: summary)
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
    private func usageAlerts(for summary: UsageSummary) -> [LocalNotification] {
        let stored = defaults.data(forKey: Keys.usageAlertState).flatMap { try? JSONDecoder().decode(UsageAlertState.self, from: $0) }
        var state = stored ?? UsageAlertState()
        let notifications = UsageAlertPlanner.alerts(for: summary, rules: preferences.usage, state: &state)
        if state != stored, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Keys.usageAlertState)
        }
        return notifications
    }

    private func rememberStuck(_ runIDs: Set<String>) {
        guard runIDs != reportedStuckRunIDs else { return }
        reportedStuckRunIDs = runIDs
        defaults.set(runIDs.sorted(), forKey: Keys.reportedStuckRunIDs)
    }

    private enum Keys {
        static let reportedStuckRunIDs = "notifications.builds.reportedStuckRunIDs"
        static let usageAlertState = "notifications.usage.alertState"
    }
}
