import Foundation

/// What the window's toolbar offers about fetching: a button to refresh, or the sign that a request is under way.
nonisolated enum RefreshControl: Equatable, Sendable {
    case ready
    /// Something is being read from Apple: nothing more is asked until it is done.
    case busy
    case held(Hold)

    nonisolated enum Hold: Equatable, Sendable {
        /// Apple answered 429. The app waits on its own, and each further refusal doubles that wait.
        case rateLimited
        /// The key's hourly budget is nearly spent.
        case lowBudget
    }

    /// `isLoading` is what the window reads for itself besides the sync: a build's sheet, older builds, pull requests.
    static func current(isSyncing: Bool, isLoading: Bool, lastError: AppStoreConnectError?, budget: RateLimit?) -> RefreshControl {
        if isSyncing || isLoading { return .busy }
        if lastError == .rateLimited { return .held(.rateLimited) }
        if let budget, budget.remaining <= SyncSchedule.criticalRemaining { return .held(.lowBudget) }
        return .ready
    }

    var allowsRefresh: Bool {
        self == .ready
    }

    var isHeld: Bool {
        if case .held = self { true } else { false }
    }
}
