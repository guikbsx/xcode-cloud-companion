import Foundation

/// What the app is doing with Apple right now, or how fresh its data is: the line above the Cycle card.
nonisolated enum SyncActivity: Equatable, Sendable {
    /// The first sync, then the test results fetched pass after pass: it lasts minutes, and says how far it is.
    case measuring(MeasurementProgress, isFirstSync: Bool, activity: String?)
    /// An ordinary sync, a second or two long. `activity` is the step under way ("Listing builds of …").
    case syncing(activity: String?)
    case failed(message: String)
    case idle(lastSync: Date?)

    /// The same reading as the menu: a first sync or builds still to measure come before everything else.
    static func current(
        isSyncing: Bool, activity: String?, lastSync: Date?, errorMessage: String?, measurement: MeasurementProgress?
    ) -> SyncActivity {
        let isFirstSync = isSyncing && lastSync == nil
        if isFirstSync || measurement?.isMeasuring == true {
            return .measuring(measurement ?? MeasurementProgress(), isFirstSync: isFirstSync, activity: activity)
        }
        if isSyncing {
            return .syncing(activity: activity)
        }
        if let errorMessage {
            return .failed(message: errorMessage)
        }
        return .idle(lastSync: lastSync)
    }

    /// Another account's first fetch or measure, to show next to the account on screen: it goes on in the background, and
    /// the window is not the place to hide it. Nil when no other account has anything lasting under way.
    static func background(among others: [(name: String, activity: SyncActivity)]) -> (name: String, activity: SyncActivity)? {
        others.first { $0.activity.isCard }
    }

    /// The card takes room; the line does not, so the sidebar keeps its height from one sync to the next.
    var isCard: Bool {
        if case .measuring = self { true } else { false }
    }
}
