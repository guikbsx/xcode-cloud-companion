import Foundation

/// What the overview of one app shows, worked out from what the app already holds: no request, no disk.
///
/// The figures are the ones shown elsewhere, scoped to the app: `UsageSummary` for the minutes, `WorkflowTrends` for how
/// the builds go, `ScheduleForecast` for what is coming, `ReferencesModel` for the branches.
nonisolated struct AppOverviewModel: Equatable, Sendable {
    /// The app's part of the cycle; absent while no reset date is set.
    struct Cycle: Equatable, Sendable {
        let billedMinutes: Double
        let estimatedMinutes: Double
        let quotaMinutes: Double
        /// What the whole account used, this app included.
        let accountMinutes: Double
        /// Minutes the cycle ends with for this app if its pace holds; nil while the cycle is too young to tell.
        let projectedMinutes: Double?
        /// The app's workflows, costliest first, then the other apps: what the cycle's bar is cut into.
        let segments: [Segment]
        /// Builds still being measured: no figure that depends on them is shown yet.
        let isMeasuring: Bool
        let lastImport: Date?

        var totalMinutes: Double { billedMinutes + estimatedMinutes }
        var fractionOfPlan: Double { quotaMinutes > 0 ? totalMinutes / quotaMinutes : 0 }
        /// Share of what the account used in the cycle; nil when nothing was used.
        var shareOfUsed: Double? { accountMinutes > 0 ? min(totalMinutes / accountMinutes, 1) : nil }
        var hasEstimates: Bool { estimatedMinutes > 0 }

        /// The cycle card's skeleton, while the builds it rests on are measured: figures of a typical length, none of them shown.
        static let placeholder = Cycle(
            billedMinutes: 0, estimatedMinutes: 135, quotaMinutes: 1_500, accountMinutes: 400, projectedMinutes: 320,
            segments: [Segment(workflow: "Release", minutes: 90, shade: 1), Segment(workflow: "Main", minutes: 45, shade: 0.78), Segment(workflow: nil, minutes: 120, shade: 1)],
            isMeasuring: false, lastImport: nil
        )
    }

    struct Segment: Identifiable, Equatable, Sendable {
        /// The workflow's name; nil for the slice of the other apps.
        let workflow: String?
        let minutes: Double
        /// How strong the app's colour is on this slice: lighter for each further workflow.
        let shade: Double

        var id: String { workflow ?? "\u{0}others" }
    }

    /// What makes a workflow start when no schedule does.
    enum Trigger: Equatable, Sendable {
        case branch, tag, pullRequest
    }

    enum Next: Equatable, Sendable {
        /// A scheduled start, and what one run costs when the cycle has one to tell from.
        case scheduled(Date, minutes: Double?)
        /// A change starts it; `source` names the branches, tags or pull requests when it is not all of them.
        case onChange(Trigger, source: String?)
    }

    struct WorkflowRow: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// The Xcode the workflow builds with, as Apple names it.
        let xcodeVersion: String?
        let xcodeWarning: XcodeVersionCheck.Warning?
        let isPaused: Bool
        let lastRun: CIBuildRun?
        let successRate: Double?
        let successDrift: WorkflowTrends.Drift?
        let medianDuration: TimeInterval?
        let durationDrift: WorkflowTrends.Drift?
        /// Minutes in the cycle; nil without a cycle.
        let cycleMinutes: Double?
        let cycleBuilds: Int
        let isEstimated: Bool
        let next: Next?
        /// How strong the app's colour is for this workflow: lighter for each further one.
        var shade: Double

        var lastStatus: BuildStatus? { lastRun.map(BuildStatus.init(run:)) }
    }

    /// The app as a whole, under its workflows.
    struct Total: Equatable, Sendable {
        let successRate: Double?
        let medianDuration: TimeInterval?
        let cycleMinutes: Double?
        let isEstimated: Bool
        /// Estimated minutes of the scheduled runs until the cycle resets; nil without a cycle or without a schedule.
        let upcomingMinutes: Double?
    }

    /// How many references the overview lists.
    static let visibleReferences = 4

    let productID: String
    /// The product name: the key of the app's colour, of its usage and of its icon.
    let productKey: String
    let displayName: String
    /// “owner/repository”, when a workflow names it.
    let repository: String?
    let cycle: Cycle?
    let workflows: [WorkflowRow]
    let total: Total
    /// The app's newest finished builds, oldest first, and how long they waited for a machine.
    let bars: [WorkflowTrends.Bar]
    let medianQueueWait: TimeInterval?
    let references: [ReferenceRow]
    let costliestBuild: BuildCost?
    /// The run behind `costliestBuild`, to open it.
    let costliestRunID: String?
    /// The newest successful build of a workflow that hands its archive to TestFlight.
    let testFlightRun: CIBuildRun?

    /// `details` are the workflows as their own sheet read them, richer than the sync's: they win where both exist.
    /// `openPullRequests` is Apple's list when it is known; nil shows every pull request the builds name.
    init?(
        productID: String, snapshot: BuildSnapshot, details: [String: CIWorkflow] = [:], summary: UsageSummary?,
        openPullRequests: OpenPullRequests? = nil, now: Date, calendar: Calendar = .current
    ) {
        guard let product = snapshot.products.first(where: { $0.id == productID }) else { return nil }
        self.productID = productID
        productKey = product.name
        displayName = product.displayName

        let runs = snapshot.runs.filter { $0.productID == productID }
        let runsByWorkflow = Dictionary(grouping: runs.filter { $0.workflowID != nil }, by: { $0.workflowID ?? "" })
        let known = snapshot.workflows
            .filter { $0.productID == productID || ($0.productID == nil && runsByWorkflow[$0.id] != nil) }
            .map { details[$0.id] ?? $0 }
        repository = known.lazy.compactMap { $0.repositoryName?.nilIfBlank }.first

        let usage = (summary?.byWorkflow ?? []).filter { $0.product == product.name }
        let forecast = ScheduleForecast(
            workflows: known, products: snapshot.products, cycleEnd: summary?.cycle.end, usage: summary?.byWorkflow ?? [], now: now, calendar: calendar
        )
        let scheduled = Dictionary(forecast.entries.map { ($0.workflowID, $0) }, uniquingKeysWith: { first, _ in first })

        var rows = known.map { workflow -> WorkflowRow in
            let own = runsByWorkflow[workflow.id] ?? []
            let trends = WorkflowTrends(runs: own)
            let used = usage.first { $0.workflow == workflow.name }
            return WorkflowRow(
                id: workflow.id, name: workflow.name,
                xcodeVersion: workflow.xcodeVersionName?.nilIfBlank ?? workflow.xcodeVersion.map { "Xcode \($0)" },
                xcodeWarning: XcodeVersionCheck.warning(version: workflow.xcodeVersion, name: workflow.xcodeVersionName, among: snapshot.xcodeVersions),
                isPaused: workflow.isEnabled == false,
                lastRun: own.max { Self.order($0) < Self.order($1) },
                successRate: trends.successRate, successDrift: trends.successDrift,
                medianDuration: trends.medianDuration, durationDrift: trends.durationDrift,
                cycleMinutes: summary == nil ? nil : used?.totalMinutes ?? 0, cycleBuilds: used?.buildCount ?? 0,
                isEstimated: (used?.estimatedMinutes ?? 0) > 0,
                next: scheduled[workflow.id].map { .scheduled($0.nextRun, minutes: $0.minutesPerRun) } ?? Self.trigger(of: workflow),
                shade: 1
            )
        }
        // Costliest first, like the Overview; then the one that built last.
        rows.sort {
            let (a, b) = ($0.cycleMinutes ?? 0, $1.cycleMinutes ?? 0)
            if a != b { return a > b }
            let (left, right) = ($0.lastRun.map(Self.order), $1.lastRun.map(Self.order))
            if let left, let right, left != right { return left > right }
            if (left == nil) != (right == nil) { return left != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for index in rows.indices {
            rows[index].shade = max(0.35, 1 - 0.22 * Double(index))
        }
        workflows = rows

        let appTrends = WorkflowTrends(runs: runs)
        bars = appTrends.bars
        medianQueueWait = appTrends.medianQueueWait

        let appUsage = summary?.byApp.first { $0.product == product.name }
        if let summary {
            let billed = appUsage?.billedMinutes ?? 0
            let estimated = appUsage?.estimatedMinutes ?? 0
            let elapsed = now.timeIntervalSince(summary.cycle.start)
            var segments = workflows.compactMap { row -> Segment? in
                guard let minutes = row.cycleMinutes, minutes > 0 else { return nil }
                return Segment(workflow: row.name, minutes: minutes, shade: row.shade)
            }
            // Builds whose workflow is gone, or that an export lists without one, still belong to the app.
            let unnamed = billed + estimated - segments.reduce(0) { $0 + $1.minutes }
            if unnamed > 0.01 {
                segments.append(Segment(workflow: String(localized: "Other workflows"), minutes: unnamed, shade: 0.35))
            }
            let others = summary.usedMinutes - (billed + estimated)
            if others > 0.01 {
                segments.append(Segment(workflow: nil, minutes: others, shade: 1))
            }
            cycle = Cycle(
                billedMinutes: billed, estimatedMinutes: estimated, quotaMinutes: summary.quotaMinutes, accountMinutes: summary.usedMinutes,
                projectedMinutes: elapsed >= UsageSummary.minimumElapsedForPace ? (billed + estimated) / elapsed * summary.cycle.duration : nil,
                segments: segments, isMeasuring: summary.measurement.isMeasuring, lastImport: summary.lastImport
            )
        } else {
            cycle = nil
        }

        let hasSchedule = forecast.entries.contains { $0.productKey == product.name }
        total = Total(
            successRate: appTrends.successRate, medianDuration: appTrends.medianDuration,
            cycleMinutes: summary == nil ? nil : appUsage?.totalMinutes ?? 0, isEstimated: (appUsage?.estimatedMinutes ?? 0) > 0,
            upcomingMinutes: hasSchedule ? forecast.minutesUntilReset : nil
        )

        var scoped = snapshot
        scoped.runs = runs
        references = Array(ReferencesModel(snapshot: scoped, openPullRequests: openPullRequests, now: now, calendar: calendar).rows.prefix(Self.visibleReferences))

        costliestBuild = summary?.costliestBuildByApp[product.name]
        costliestRunID = costliestBuild.flatMap { cost in runs.first { $0.number == cost.buildNumber }?.id }

        let shipping = Set(known.filter(\.shipsToTestFlight).map(\.id))
        testFlightRun = runs
            .filter { $0.completionStatus == .succeeded && $0.workflowID.map(shipping.contains) == true }
            .max { Self.order($0) < Self.order($1) }
    }

    /// What starts the workflow, as far as its conditions are known: a branch first, then a pull request, then a tag.
    static func trigger(of workflow: CIWorkflow) -> Next? {
        guard let conditions = workflow.startConditions else { return nil }
        func source(_ patterns: CIPatterns) -> String? {
            patterns.isAllMatch || patterns.patterns.isEmpty ? nil : patterns.patterns.joined(separator: ", ")
        }
        if let branches = conditions.branches { return .onChange(.branch, source: source(branches)) }
        if let pullRequests = conditions.pullRequests { return .onChange(.pullRequest, source: source(pullRequests)) }
        if let tags = conditions.tags { return .onChange(.tag, source: source(tags)) }
        return nil
    }

    private static func order(_ run: CIBuildRun) -> (Date, Int) {
        (run.createdDate ?? .distantPast, run.number ?? 0)
    }
}
