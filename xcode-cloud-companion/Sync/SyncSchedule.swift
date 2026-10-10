import Foundation

nonisolated enum SyncOutcome: Sendable, Equatable {
    case succeeded(hasActiveBuilds: Bool)
    case rateLimited(consecutive: Int)
    case failed
    case notConfigured
}

/// What the pace of the refresh depends on besides the last outcome.
nonisolated struct SyncContext: Sendable, Equatable {
    var windowIsOpen = false
    var screenIsLocked = false
    /// Apple's hourly budget for the key, as of its last response.
    var budget: RateLimit?
}

nonisolated enum SyncSchedule {
    static let whileBuilding: Duration = .seconds(60)
    /// The window is open and watching a build: closer, but never below what one request per minute of the key costs.
    static let whileBuildingWithWindow: Duration = .seconds(30)
    static let idle: Duration = .seconds(10 * 60)
    static let idleWithWindow: Duration = .seconds(5 * 60)
    static let afterFailure: Duration = .seconds(5 * 60)
    static let afterRateLimit: Duration = .seconds(15 * 60)
    static let longestWait: Duration = .seconds(2 * 3600)
    /// Fewer requests than this left in the hour: nothing but the slowest pace.
    static let criticalRemaining = 50

    static func delay(after outcome: SyncOutcome, context: SyncContext = SyncContext()) -> Duration {
        switch outcome {
        case .succeeded(let hasActiveBuilds):
            // A locked screen shows nobody anything: it never goes faster than the slow pace.
            let base: Duration = if context.screenIsLocked {
                idle
            } else if hasActiveBuilds {
                context.windowIsOpen ? whileBuildingWithWindow : whileBuilding
            } else {
                context.windowIsOpen ? idleWithWindow : idle
            }
            return min(base * budgetFactor(context.budget), longestWait)
        case .rateLimited(let consecutive):
            return min(afterRateLimit * (1 << min(max(consecutive - 1, 0), 8)), longestWait)
        case .failed:
            return afterFailure
        case .notConfigured:
            return idle
        }
    }

    /// The pace slows as the hourly budget runs down, well before it reaches zero.
    static func budgetFactor(_ budget: RateLimit?) -> Int {
        guard let budget else { return 1 }
        if budget.remaining <= criticalRemaining { return 20 }
        switch budget.fractionRemaining {
        case ..<0.1: return 8
        case ..<0.25: return 4
        case ..<0.5: return 2
        default: return 1
        }
    }

    static func isDue(lastRun: Date, now: Date, outcome: SyncOutcome, context: SyncContext) -> Bool {
        let wait = delay(after: outcome, context: context).components
        let seconds = Double(wait.seconds) + Double(wait.attoseconds) / 1e18
        return now.timeIntervalSince(lastRun) >= seconds
    }
}
