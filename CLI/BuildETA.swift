import Foundation

/// When a running build should end: its workflow's median duration over the builds that succeeded, counted from the
/// build's own start. Read from the cache alone, never from a request.
nonisolated struct BuildETA: Equatable, Sendable {
    /// How many succeeded builds of the workflow, newest first, the median is taken over.
    static let sampleLimit = 30
    /// Below this many builds the median says nothing.
    static let minimumSample = 3
    /// A text is sure of nothing finer than this: under it the estimate reads “less than a minute”.
    static let wholeMinute: TimeInterval = 60

    /// What an estimate says once it is rounded, the only two words a menu bar item has room for.
    enum Display: Equatable, Sendable {
        case underAMinute
        case minutes(Int)
    }

    let runID: String
    let startedDate: Date
    let medianDuration: TimeInterval
    let sampleSize: Int

    var expectedEnd: Date { startedDate.addingTimeInterval(medianDuration) }

    /// `run` must be running (not queued) and past its start; its workflow needs `minimumSample` succeeded builds in
    /// `runs`. Nil also once the median is over: an estimate that has passed is dropped, not shown as zero.
    init?(run: CIBuildRun, among runs: [CIBuildRun], now: Date) {
        guard run.executionProgress == .running, let started = run.startedDate,
              let sample = Self.durations(for: run, among: runs), sample.count >= Self.minimumSample,
              let median = WorkflowTrends.median(sample),
              started.addingTimeInterval(median).timeIntervalSince(now) > 0
        else { return nil }
        runID = run.id
        startedDate = started
        medianDuration = median
        sampleSize = sample.count
    }

    func remaining(at now: Date) -> TimeInterval {
        expectedEnd.timeIntervalSince(now)
    }

    /// Elapsed over the median, from 0 to 1.
    func progress(at now: Date) -> Double {
        guard medianDuration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(startedDate) / medianDuration))
    }

    func display(at now: Date) -> Display? {
        Self.display(remaining: remaining(at: now))
    }

    /// Nil when nothing is left: never a negative duration, never “0 min”.
    static func display(remaining: TimeInterval) -> Display? {
        guard remaining > 0 else { return nil }
        guard remaining >= wholeMinute else { return .underAMinute }
        return .minutes(Int((remaining / wholeMinute).rounded()))
    }

    /// The moment the text of `display(remaining:)` next differs, for a task that sleeps until then.
    static func nextChange(remaining: TimeInterval, from now: Date) -> Date? {
        guard remaining > 0 else { return nil }
        let boundary: TimeInterval
        if remaining < wholeMinute {
            boundary = 0
        } else {
            let minutes = (remaining / wholeMinute).rounded()
            boundary = minutes <= 1 ? wholeMinute : (minutes - 0.5) * wholeMinute
        }
        return now.addingTimeInterval(remaining - boundary + 0.1)
    }

    /// Seconds from start to end of the workflow's newest succeeded builds; nil for a build without workflow.
    static func durations(for run: CIBuildRun, among runs: [CIBuildRun]) -> [TimeInterval]? {
        guard let workflowID = run.workflowID else { return nil }
        return runs
            .filter { $0.workflowID == workflowID && $0.executionProgress == .complete && $0.completionStatus == .succeeded }
            .sorted { ($0.createdDate ?? .distantPast, $0.number ?? 0) > ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            .compactMap { build -> TimeInterval? in
                guard let started = build.startedDate, let finished = build.finishedDate, finished > started else { return nil }
                return finished.timeIntervalSince(started)
            }
            .prefix(sampleLimit)
            .map { $0 }
    }
}

/// The builds running now across accounts, and when the nearest ends: what the menu bar says.
nonisolated struct RunningBuildsETA: Equatable, Sendable {
    /// One running build of a snapshot, with its estimate when there is one.
    struct Entry: Equatable, Sendable {
        let run: CIBuildRun
        let eta: BuildETA?
    }

    /// Builds queued or running.
    let runningCount: Int
    /// Seconds left of the nearest estimate; nil when no running build has one.
    let remaining: TimeInterval?
    /// When the text next changes, if it does.
    let nextChange: Date?

    var display: BuildETA.Display? {
        remaining.flatMap(BuildETA.display(remaining:))
    }

    init(runningCount: Int, remaining: TimeInterval?, nextChange: Date? = nil) {
        self.runningCount = runningCount
        self.remaining = remaining
        self.nextChange = nextChange
    }

    /// One snapshot's running builds, those that end first at the head, those with no estimate after them, those still queued last.
    static func entries(in snapshot: BuildSnapshot, now: Date) -> [Entry] {
        let entries = snapshot.runs
            .filter { $0.executionProgress == .running || $0.executionProgress == .pending }
            .map { Entry(run: $0, eta: BuildETA(run: $0, among: snapshot.runs, now: now)) }
        return entries.sorted(by: precedes)
    }

    /// The order of the builds in the menu bar, the menu and the list: the nearest end first, then those with no estimate, queued ones last.
    static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.eta, rhs.eta) {
        case let (left?, right?): left.expectedEnd < right.expectedEnd
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil):
            if (lhs.run.executionProgress == .pending) != (rhs.run.executionProgress == .pending) {
                rhs.run.executionProgress == .pending
            } else {
                (lhs.run.createdDate ?? .distantPast, lhs.run.number ?? 0) < (rhs.run.createdDate ?? .distantPast, rhs.run.number ?? 0)
            }
        }
    }

    /// Every account's snapshot: the count is all of their running builds, the time is the nearest end among them.
    init(snapshots: [BuildSnapshot], now: Date) {
        let entries = snapshots.flatMap { Self.entries(in: $0, now: now) }
        let etas = entries.compactMap(\.eta)
        runningCount = entries.count
        remaining = etas.map { $0.remaining(at: now) }.min()
        nextChange = etas.compactMap { BuildETA.nextChange(remaining: $0.remaining(at: now), from: now) }.min()
    }
}
