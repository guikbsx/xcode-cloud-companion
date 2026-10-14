import Foundation

/// When an app's TestFlight builds are asked for. A build in motion is followed closely; the rest of the time a day is
/// enough to see a build expire. Nothing is asked while the hour's requests are nearly spent.
nonisolated enum TestFlightCadence {
    static let pendingInterval: TimeInterval = 15 * 60
    static let idleInterval: TimeInterval = 24 * 3600
    /// After a successful build of a workflow that ships to TestFlight, its upload is looked for this long.
    static let expectingWindow: TimeInterval = 30 * 60

    /// A build whose state is about to change: it is processed, or the beta review has not given its answer.
    static func isPending(_ builds: [TestFlightBuild], now: Date) -> Bool {
        builds.contains { [.processing, .waitingForReview, .inReview].contains($0.status(at: now)) }
    }

    /// Xcode Cloud just finished a build that ships to TestFlight and no TestFlight build of the last hour is known: it is on its way.
    static func isExpectingBuild(app: TestFlightApp, builds: [TestFlightBuild], now: Date) -> Bool {
        guard let finish = app.newestShippedFinish, now.timeIntervalSince(finish) < expectingWindow else { return false }
        return !builds.contains { ($0.uploadedDate ?? .distantPast) >= finish.addingTimeInterval(-3600) }
    }

    /// `lastFailure` is when the last attempt failed in this session: a failed read is tried again at the quick pace, not at once.
    static func isDue(
        app: TestFlightApp, reading: TestFlightReading?, lastFailure: Date? = nil, now: Date, remainingRequests: Int? = nil
    ) -> Bool {
        if let remainingRequests, remainingRequests <= SyncSchedule.criticalRemaining { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < pendingInterval { return false }
        guard let reading else { return true }
        let age = now.timeIntervalSince(reading.readAt)
        let isMoving = isPending(reading.builds, now: now)
            || isExpectingBuild(app: app, builds: reading.builds, now: now)
            || (app.newestShippedFinish.map { $0 > reading.readAt } ?? false)
        return age >= (isMoving ? pendingInterval : idleInterval)
    }
}
