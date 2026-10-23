import Foundation

/// The mosaic of the Overview: for each workflow, how every one of the last days went. Worked out from the snapshot
/// and the usage summary alone, with no request and no disk read; the view only draws it.
///
/// Rows follow the sidebar: apps in its order, each app's workflows by name. Columns run from the oldest day to today,
/// in the calendar and time zone of the Mac. A build belongs to the day it was created on, so one that finishes after
/// midnight stays on the day it started.
nonisolated struct OverviewMosaic: Equatable, Sendable {
    /// The cache keeps 35 days of builds.
    static let defaultDays = 35
    /// A cell is as dark as its builds are many, up to this many.
    static let maximumIntensity = 4
    /// The figures at the end of a row look at this many days, ending today.
    static let recentDays = 7
    /// A median that moves by less than this, as a fraction of the earlier one, is stable.
    static let trendThreshold = 0.15
    /// Builds needed on each side for a trend to mean something.
    static let trendMinimumPerSide = 3

    /// How a day went for one workflow.
    enum Outcome: Equatable, Sendable {
        /// No build finished with a verdict that day: no build at all, or only builds canceled, skipped or still going.
        case none
        case succeeded
        /// At least one failure (`FAILED` or `ERRORED`) and no success.
        case failed
        /// Both a success and a failure.
        case mixed
    }

    struct Cell: Equatable, Sendable {
        /// The start of the day.
        let day: Date
        /// Every build of the day, canceled and skipped ones and the ones still going included.
        let builds: Int
        let succeeded: Int
        /// `FAILED` and `ERRORED`.
        let failed: Int
        let running: Int
        let queued: Int

        var outcome: Outcome {
            switch (succeeded > 0, failed > 0) {
            case (true, true): .mixed
            case (true, false): .succeeded
            case (false, true): .failed
            case (false, false): .none
            }
        }

        /// 0 without a build, then 1 to 4, where 4 is four builds or more.
        var intensity: Int { min(builds, OverviewMosaic.maximumIntensity) }
    }

    /// The median build time of the last days against the days before.
    enum Trend: Equatable, Sendable {
        /// Fewer than three builds on one side.
        case unknown
        case stable
        /// The change as a fraction of the earlier median: `+0.2` is 20 % longer.
        case up(Double)
        case down(Double)
    }

    /// A workflow's minutes in the cycle, as `UsageSummary` counts them.
    struct CycleMinutes: Equatable, Sendable {
        let minutes: Double
        /// Some of them are computed from the build's actions rather than billed by Apple.
        let isEstimated: Bool
    }

    /// The run of failures that ends a workflow's newest finished build: “since #203, 3 failures in a row”.
    struct FailureSeries: Equatable, Sendable {
        /// The first build of the run, and the last one (the newest finished build of the workflow).
        let firstRunID: String
        let firstNumber: Int?
        let firstDate: Date?
        let lastRunID: String
        let lastNumber: Int?
        let lastDate: Date?
        let failureCount: Int
        /// No success is in the cache before the first failure: the run may be older than it looks.
        let isOpenEnded: Bool

        /// The start of the day of the first failure.
        func firstDay(calendar: Calendar) -> Date? {
            firstDate.map { calendar.startOfDay(for: $0) }
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let workflowID: String
        let name: String
        let productID: String
        /// The product's name: the key of its colour and of its usage.
        let productKey: String
        let isPaused: Bool
        /// One per day of the mosaic, the oldest first.
        let cells: [Cell]
        /// Succeeded over finished, canceled and skipped builds left out, over the last 7 days; nil without a finished build.
        let successRate: Double?
        /// Of the succeeded builds of the last 7 days; nil without one.
        let medianSeconds: TimeInterval?
        let trend: Trend
        /// Nil without a plan, while usage is being measured, or when no summary was given.
        let cycle: CycleMinutes?
        /// Nil when the newest finished build succeeded, or when there is none.
        let failureSeries: FailureSeries?

        var id: String { workflowID }
        var buildsLastDays: Int { cells.suffix(OverviewMosaic.recentDays).reduce(0) { $0 + $1.builds } }
    }

    /// One app's rows.
    struct Group: Identifiable, Equatable, Sendable {
        let productID: String
        /// The name shown.
        let name: String
        let productKey: String
        let swatch: AppSwatch
        let rows: [Row]

        var id: String { productID }
    }

    /// The days of the columns, the oldest first, the last one today.
    let days: [Date]
    let groups: [Group]
    /// Workflows with no build in the period, which have no row.
    let hiddenWorkflowCount: Int
    let now: Date

    var rows: [Row] { groups.flatMap(\.rows) }
    var isEmpty: Bool { groups.isEmpty }
    /// Builds of the last 7 days, all rows together: “7 days: 46 builds”.
    var buildsLastDays: Int { rows.reduce(0) { $0 + $1.buildsLastDays } }

    /// `sidebar` gives the order and the names; `summary` the minutes, and is nil when the account has no plan.
    init(
        snapshot: BuildSnapshot, sidebar: SidebarContent, summary: UsageSummary? = nil, now: Date,
        calendar: Calendar = .current, days dayCount: Int = OverviewMosaic.defaultDays
    ) {
        self.now = now
        let today = calendar.startOfDay(for: now)
        let count = max(dayCount, 1)
        let days = (0..<count).reversed().map { offset in
            calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        }
        self.days = days
        let dayIndex = Dictionary(days.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        let recentStart = days[max(count - Self.recentDays, 0)]
        let earlierStart = calendar.date(byAdding: .day, value: -Self.recentDays, to: recentStart) ?? recentStart
        let cycleByWorkflow = Self.cycleMinutes(summary)
        let runsByWorkflow = Dictionary(grouping: snapshot.runs.filter { $0.workflowID != nil }, by: { $0.workflowID ?? "" })

        var hidden = 0
        var groups: [Group] = []
        for product in sidebar.products {
            var rows: [Row] = []
            for workflow in product.workflows {
                let runs = runsByWorkflow[workflow.id] ?? []
                var tallies = [Tally](repeating: Tally(), count: count)
                var inPeriod = false
                for run in runs {
                    guard let date = Self.date(of: run), date <= now,
                          let index = dayIndex[calendar.startOfDay(for: date)]
                    else { continue }
                    inPeriod = true
                    tallies[index].add(run)
                }
                guard inPeriod else {
                    hidden += 1
                    continue
                }
                let cells = zip(days, tallies).map { day, tally in
                    Cell(day: day, builds: tally.builds, succeeded: tally.succeeded, failed: tally.failed, running: tally.running, queued: tally.queued)
                }
                let figures = Self.figures(of: runs, recentStart: recentStart, earlierStart: earlierStart, now: now, calendar: calendar)
                rows.append(Row(
                    workflowID: workflow.id, name: workflow.name, productID: product.id, productKey: product.paletteKey,
                    isPaused: workflow.isPaused, cells: cells, successRate: figures.successRate, medianSeconds: figures.median,
                    trend: figures.trend, cycle: cycleByWorkflow.map { $0[Self.key(product.paletteKey, workflow.name)] ?? CycleMinutes(minutes: 0, isEstimated: false) },
                    failureSeries: Self.failureSeries(of: runs)
                ))
            }
            if !rows.isEmpty {
                groups.append(Group(productID: product.id, name: product.name, productKey: product.paletteKey, swatch: product.swatch, rows: rows))
            }
        }
        self.groups = groups
        hiddenWorkflowCount = hidden
    }

    // MARK: - Private

    /// What a day's builds add up to.
    private struct Tally {
        var builds = 0
        var succeeded = 0
        var failed = 0
        var running = 0
        var queued = 0

        mutating func add(_ run: CIBuildRun) {
            builds += 1
            switch run.executionProgress {
            case .pending: queued += 1
            case .running: running += 1
            case .complete, .unknown:
                switch run.completionStatus {
                case .succeeded: succeeded += 1
                case .failed, .errored: failed += 1
                default: break
                }
            }
        }
    }

    private static func date(of run: CIBuildRun) -> Date? {
        run.createdDate ?? run.startedDate
    }

    private static func key(_ product: String, _ workflow: String) -> String {
        "\(product)|\(workflow)"
    }

    /// Nil without a plan or while results are still being measured: the Overview shows no minutes then.
    private static func cycleMinutes(_ summary: UsageSummary?) -> [String: CycleMinutes]? {
        guard let summary, summary.quotaMinutes > 0, !summary.measurement.isMeasuring else { return nil }
        return Dictionary(
            summary.byWorkflow.map { (key($0.product, $0.workflow), CycleMinutes(minutes: $0.totalMinutes, isEstimated: $0.estimatedMinutes > 0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func figures(
        of runs: [CIBuildRun], recentStart: Date, earlierStart: Date, now: Date, calendar: Calendar
    ) -> (successRate: Double?, median: TimeInterval?, trend: Trend) {
        var verdicts: [Bool] = []
        var recentDurations: [Double] = []
        var earlierDurations: [Double] = []
        for run in runs where run.executionProgress == .complete {
            guard let date = date(of: run), date <= now else { continue }
            let day = calendar.startOfDay(for: date)
            guard day >= earlierStart else { continue }
            let isRecent = day >= recentStart
            switch run.completionStatus {
            case .succeeded:
                if isRecent { verdicts.append(true) }
                if let started = run.startedDate, let finished = run.finishedDate, finished >= started {
                    let seconds = finished.timeIntervalSince(started)
                    if isRecent { recentDurations.append(seconds) } else { earlierDurations.append(seconds) }
                }
            case .failed, .errored:
                if isRecent { verdicts.append(false) }
            default:
                break
            }
        }
        let rate = verdicts.isEmpty ? nil : Double(verdicts.filter { $0 }.count) / Double(verdicts.count)
        return (rate, WorkflowTrends.median(recentDurations), trend(recent: recentDurations, earlier: earlierDurations))
    }

    private static func trend(recent: [Double], earlier: [Double]) -> Trend {
        guard recent.count >= trendMinimumPerSide, earlier.count >= trendMinimumPerSide,
              let now = WorkflowTrends.median(recent), let before = WorkflowTrends.median(earlier)
        else { return .unknown }
        guard before > 0 else { return now == 0 ? .stable : .up(1) }
        let fraction = (now - before) / before
        if abs(fraction) < trendThreshold { return .stable }
        return fraction > 0 ? .up(fraction) : .down(fraction)
    }

    /// Finished builds newest first, canceled and skipped ones left out (they neither break a run nor extend it).
    private static func failureSeries(of runs: [CIBuildRun]) -> FailureSeries? {
        let finished = runs
            .filter { $0.executionProgress == .complete }
            .sorted { (date(of: $0) ?? .distantPast, $0.number ?? 0) > (date(of: $1) ?? .distantPast, $1.number ?? 0) }
            .compactMap { run -> (run: CIBuildRun, failed: Bool)? in
                switch run.completionStatus {
                case .succeeded: (run, false)
                case .failed, .errored: (run, true)
                default: nil
                }
            }
        guard let newest = finished.first, newest.failed else { return nil }
        let series = finished.prefix { $0.failed }
        guard let first = series.last?.run else { return nil }
        return FailureSeries(
            firstRunID: first.id, firstNumber: first.number, firstDate: date(of: first),
            lastRunID: newest.run.id, lastNumber: newest.run.number, lastDate: date(of: newest.run),
            failureCount: series.count, isOpenEnded: series.count == finished.count
        )
    }
}
