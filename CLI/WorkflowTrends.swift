import Foundation

/// How a workflow's builds go over time, read from the cache alone: median duration, median wait in Apple's queue,
/// success rate, and whether the newest builds drift from the ones before. Shared with the `cumulus` command.
nonisolated struct WorkflowTrends: Equatable, Sendable {
    /// How many finished builds a report looks at, newest first.
    static let sampleLimit = 30
    /// Below this many builds there is nothing to compare: no drift is given.
    static let driftMinimum = 6
    /// The newest builds compared with the ones before them.
    static let recentCount = 10
    /// A drift smaller than this is "stable".
    static let driftThreshold = 0.15

    /// One finished build of the sample, oldest first.
    struct Bar: Identifiable, Equatable, Sendable {
        let id: String
        let number: Int?
        let seconds: TimeInterval
        let succeeded: Bool
        let createdDate: Date?
    }

    /// The newest builds against the ones before, as a fraction of the earlier value: +0.18 is 18 % more.
    enum Drift: Equatable, Sendable {
        case stable
        case change(Double)

        var fraction: Double {
            if case .change(let value) = self { value } else { 0 }
        }
    }

    let sampleSize: Int
    /// Seconds from start to end, over builds that ran; nil without one.
    let medianDuration: TimeInterval?
    /// Seconds between creation and start: the time spent waiting for a machine.
    let medianQueueWait: TimeInterval?
    /// Succeeded over finished, canceled and skipped builds left out; nil without one.
    let successRate: Double?
    let durationDrift: Drift?
    let queueDrift: Drift?
    let successDrift: Drift?
    let bars: [Bar]

    /// `runs` are one workflow's; builds still going are left out.
    init(runs: [CIBuildRun]) {
        let finished = runs
            .filter { $0.executionProgress == .complete && $0.completionStatus != .canceled && $0.completionStatus != .skipped }
            .sorted { ($0.createdDate ?? .distantPast, $0.number ?? 0) > ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            .prefix(Self.sampleLimit)
        sampleSize = finished.count

        let durations = finished.compactMap { run -> TimeInterval? in
            guard let started = run.startedDate, let ended = run.finishedDate, ended >= started else { return nil }
            return ended.timeIntervalSince(started)
        }
        let waits = finished.compactMap { run -> TimeInterval? in
            guard let created = run.createdDate, let started = run.startedDate, started >= created else { return nil }
            return started.timeIntervalSince(created)
        }
        let outcomes = finished.map { $0.completionStatus == .succeeded ? 1.0 : 0.0 }

        medianDuration = Self.median(durations)
        medianQueueWait = Self.median(waits)
        successRate = outcomes.isEmpty ? nil : outcomes.reduce(0, +) / Double(outcomes.count)
        durationDrift = Self.drift(durations, by: Self.median)
        queueDrift = Self.drift(waits, by: Self.median)
        successDrift = Self.drift(outcomes) { values in values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

        bars = finished.reversed().compactMap { run in
            guard let started = run.startedDate, let ended = run.finishedDate, ended >= started else { return nil }
            return Bar(id: run.id, number: run.number, seconds: ended.timeIntervalSince(started), succeeded: run.completionStatus == .succeeded, createdDate: run.createdDate)
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// `values` newest first. The newest `recentCount` (half of them when there are few) against the rest.
    static func drift(_ values: [Double], by measure: ([Double]) -> Double?) -> Drift? {
        guard values.count >= driftMinimum else { return nil }
        let recent = Array(values.prefix(min(recentCount, values.count / 2)))
        let earlier = Array(values.dropFirst(recent.count))
        guard let now = measure(recent), let before = measure(earlier) else { return nil }
        if before == 0 {
            return now == 0 ? .stable : .change(1)
        }
        let fraction = (now - before) / before
        return abs(fraction) < driftThreshold ? .stable : .change(fraction)
    }
}
