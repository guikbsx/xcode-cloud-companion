import Foundation

/// When the status page may be read, and what it takes to call an incident over. Nothing here reads anything.
nonisolated enum AppleStatusSchedule {
    static let address = URL(string: "https://www.apple.com/support/systemstatus/data/developer/system_status_en_US.js")!
    static let statusPage = URL(string: "https://developer.apple.com/system-status/")!

    /// Between two reads asked by builds.
    static let minimumInterval: TimeInterval = 10 * 60
    /// Between two reads of a watch the user asked for, and how long it lasts.
    static let watchInterval: TimeInterval = 5 * 60
    static let watchLimit: TimeInterval = 12 * 3600
    /// The sheet of a build that stopped longer ago than this does not read the page.
    static let sheetFreshness: TimeInterval = 24 * 3600
    /// A build that stopped longer ago than this, found by a sync, is old news.
    static let syncFreshness: TimeInterval = 3600

    static func mayRead(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= minimumInterval || elapsed < 0
    }

    static func isErrored(_ run: CIBuildRun) -> Bool {
        run.executionProgress == .complete && run.completionStatus == .errored
    }

    /// Opening the sheet of a build that ended in error less than a day ago.
    static func sheetOpensRead(run: CIBuildRun, now: Date) -> Bool {
        guard isErrored(run), let finished = run.finishedDate else { return false }
        return now.timeIntervalSince(finished) <= sheetFreshness
    }

    /// The builds a sync saw end in error, as `BuildNotificationPlanner` sees a build end: running before and complete now,
    /// or created and finished between two syncs. A first load has no "before".
    static func erroredFinishes(previous: BuildSnapshot, current: BuildSnapshot, now: Date) -> [CIBuildRun] {
        guard let previousSync = previous.lastSuccessfulSync else { return [] }
        let before = Dictionary(previous.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.runs.filter { run in
            guard isErrored(run) else { return false }
            if let known = before[run.id] {
                guard known.executionProgress != .complete else { return false }
            } else {
                guard let created = run.createdDate, created > previousSync else { return false }
            }
            return now.timeIntervalSince(run.finishedDate ?? now) <= syncFreshness
        }
    }

    /// The builds of the given snapshots that ended in error while `interval` lasted.
    static func erroredBuilds(in snapshots: [BuildSnapshot], during interval: DateInterval) -> Int {
        snapshots.reduce(0) { total, snapshot in
            total + snapshot.runs.filter { run in
                guard isErrored(run), let finished = run.finishedDate else { return false }
                return interval.contains(finished)
            }.count
        }
    }

    enum WatchOutcome: Equatable {
        case keepWatching
        /// The incident is over; the span runs from its start to its end.
        case resolved(DateInterval)
        case expired
    }

    /// A page that cannot be read, or a read that failed (`reading` nil), never ends a watch: only a page that lists no
    /// event still going on does.
    static func watchOutcome(reading: AppleStatusReading?, incidentStart: Date, watchingSince: Date, now: Date) -> WatchOutcome {
        if case .events(let events)? = reading, !events.contains(where: \.isOngoing) {
            let end = events.first { $0.start == incidentStart }?.end ?? now
            return .resolved(DateInterval(start: incidentStart, end: max(end, incidentStart)))
        }
        return now.timeIntervalSince(watchingSince) >= watchLimit ? .expired : .keepWatching
    }
}
