import Foundation

nonisolated enum SyncOutcome: Sendable, Equatable {
    case succeeded(hasActiveBuilds: Bool)
    case rateLimited(consecutive: Int)
    case failed
    case notConfigured
}

nonisolated enum SyncSchedule {
    static let whileBuilding: Duration = .seconds(60)
    static let idle: Duration = .seconds(10 * 60)
    static let afterFailure: Duration = .seconds(5 * 60)
    static let afterRateLimit: Duration = .seconds(15 * 60)
    static let longestWait: Duration = .seconds(2 * 3600)

    static func delay(after outcome: SyncOutcome) -> Duration {
        switch outcome {
        case .succeeded(let hasActiveBuilds):
            hasActiveBuilds ? whileBuilding : idle
        case .rateLimited(let consecutive):
            min(afterRateLimit * (1 << min(max(consecutive - 1, 0), 8)), longestWait)
        case .failed:
            afterFailure
        case .notConfigured:
            idle
        }
    }
}
