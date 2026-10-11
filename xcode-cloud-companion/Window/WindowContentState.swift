import Foundation

/// What the window shows for an account, before its three columns have anything to hold.
nonisolated enum WindowContentState: Equatable, Sendable {
    /// No key: the way to Settings.
    case notSetUp
    /// The very first fetch: nothing to show yet, and what is being read.
    case loading(step: String?)
    /// The first fetch failed and there is still nothing to show; a retry may be under way.
    case failed(message: String, isRetrying: Bool)
    case ready

    /// `hasAttemptedSync` tells a start that has not looked for the key yet from a key that is missing: the first is
    /// a fetch about to begin, only the second is "not set up".
    ///
    /// The whole window only waits while the app has nothing at all to show. Once another account has its builds, a
    /// new account's first fetch must not stand in the way: the columns stay, and the sidebar's foot says how far it is.
    static func of(
        isConfigured: Bool, hasAttemptedSync: Bool, isSyncing: Bool, hasContent: Bool, anotherAccountHasContent: Bool = false,
        errorMessage: String?, step: String?
    ) -> WindowContentState {
        if hasAttemptedSync, !isConfigured, !isSyncing {
            return .notSetUp
        }
        if hasContent || anotherAccountHasContent {
            return .ready
        }
        if let errorMessage {
            return .failed(message: errorMessage, isRetrying: isSyncing)
        }
        return .loading(step: step)
    }
}
