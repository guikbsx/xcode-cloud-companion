import Foundation

nonisolated struct DailyUsage: Sendable, Equatable {
    var day: Date
    var billedMinutes: Double = 0
    var estimatedMinutes: Double = 0
    var totalMinutes: Double { billedMinutes + estimatedMinutes }
}

nonisolated struct AppUsage: Sendable, Equatable {
    var product: String
    var billedMinutes: Double = 0
    var estimatedMinutes: Double = 0
    var totalMinutes: Double { billedMinutes + estimatedMinutes }
}

/// What one workflow cost over the cycle, builds billed by Apple and builds still estimated together.
nonisolated struct WorkflowUsage: Sendable, Equatable {
    var product: String
    var workflow: String
    var billedMinutes: Double = 0
    var estimatedMinutes: Double = 0
    var buildCount = 0
    var totalMinutes: Double { billedMinutes + estimatedMinutes }
    var averageMinutes: Double { buildCount > 0 ? totalMinutes / Double(buildCount) : 0 }
}

/// The build that used the most minutes in the cycle.
nonisolated struct BuildCost: Sendable, Equatable {
    var product: String
    var buildNumber: Int
    var workflow: String?
    var minutes: Double
    /// True when the minutes are computed from the build's actions, not billed by Apple.
    var isEstimated: Bool
}

/// A slice of the gauge: `product` nil stands for the minutes that are estimated rather than billed.
nonisolated struct GaugeSegment: Sendable, Equatable {
    var product: String?
    var minutes: Double
}

/// How far the first measurements of the current cycle have got: Apple bills per simulator, so a build only counts
/// once its test results are in. Builds Apple already billed (usage export) never need measuring.
nonisolated struct MeasurementProgress: Sendable, Equatable {
    /// How many test actions one pass of the synchronizer fetches, and about how long a pass takes with the pause between passes.
    static let actionsPerPass = BuildSynchronizer.maxTestResultFetchesPerSync

    var totalActions = 0
    var measuredActions = 0
    /// Actions the synchronizer gave up on after three attempts.
    var unmeasurableActions = 0
    var pendingBuilds = 0
    var unmeasurableBuilds = 0

    var pendingActions: Int { totalActions - measuredActions - unmeasurableActions }
    var isMeasuring: Bool { pendingActions > 0 }
    var fractionDone: Double { totalActions > 0 ? Double(measuredActions + unmeasurableActions) / Double(totalActions) : 1 }
    /// One pass a minute: the whole wait, not counting the pass in flight.
    var minutesLeft: Int { (pendingActions + Self.actionsPerPass - 1) / Self.actionsPerPass }
}

/// Widths of the gauge segments, keeping every non-empty slice visible without overflowing the bar.
nonisolated enum GaugeLayout {
    static let minimumSegmentWidth: Double = 2

    static func widths(minutes: [Double], quotaMinutes: Double, totalWidth: Double) -> [Double] {
        guard quotaMinutes > 0, totalWidth > 0 else { return minutes.map { _ in 0 } }
        var widths = minutes.map { $0 > 0 ? max(minimumSegmentWidth, $0 / quotaMinutes * totalWidth) : 0 }
        let sum = widths.reduce(0, +)
        if sum > totalWidth {
            // Over quota or squeezed by the minimums: shrink the slices that exceed their minimum, never below it.
            let flexible = zip(widths, minutes).filter { $0 > minimumSegmentWidth && $1 > 0 }.reduce(0) { $0 + $1.0 }
            let fixed = sum - flexible
            let scale = flexible > 0 ? max(0, (totalWidth - fixed) / flexible) : 1
            widths = widths.map { $0 > minimumSegmentWidth ? $0 * scale : $0 }
        }
        return widths
    }
}

nonisolated struct UsageSummary: Sendable, Equatable {
    static let staleImportAge: TimeInterval = 3 * 24 * 3600
    /// Below this, the pace of a young cycle says nothing yet.
    static let minimumElapsedForPace: TimeInterval = 24 * 3600

    var plan: UsagePlan
    var cycle: DateInterval
    var now: Date
    /// Minutes App Store Connect billed, from its usage exports.
    var billedMinutes: Double
    /// Builds missing from the exports, estimated from their action durations.
    var estimatedMinutes: Double
    var estimatedBuildCount: Int
    var lastImport: Date?
    var daily: [DailyUsage]
    var buildsLast30Days: Int
    var byApp: [AppUsage]
    var measurement = MeasurementProgress()
    var byWorkflow: [WorkflowUsage] = []
    var costliestBuild: BuildCost?

    /// Gauge segments: one per app that Apple billed, biggest first, then one for everything still estimated.
    var gaugeSegments: [GaugeSegment] {
        let billed = byApp
            .filter { $0.billedMinutes > 0 }
            .sorted { ($0.billedMinutes, $1.product) > ($1.billedMinutes, $0.product) }
            .map { GaugeSegment(product: $0.product, minutes: $0.billedMinutes) }
        return estimatedMinutes > 0 ? billed + [GaugeSegment(product: nil, minutes: estimatedMinutes)] : billed
    }

    /// Every app of the cycle, biggest consumer first, for colour assignment.
    var appsByConsumption: [String] {
        byApp.map(\.product)
    }

    var usedMinutes: Double { billedMinutes + estimatedMinutes }
    var quotaMinutes: Double { Double(plan.hours * 60) }
    var availableMinutes: Double { max(0, quotaMinutes - usedMinutes) }
    var fractionUsed: Double { quotaMinutes > 0 ? usedMinutes / quotaMinutes : 0 }
    var resetDate: Date { cycle.end }
    var timeUntilReset: TimeInterval { max(0, cycle.end.timeIntervalSince(now)) }
    var isImportStale: Bool { lastImport.map { now.timeIntervalSince($0) > Self.staleImportAge } ?? true }
    var todayMinutes: Double { daily.last?.totalMinutes ?? 0 }
    var last30DaysMinutes: Double { daily.reduce(0) { $0 + $1.totalMinutes } }

    /// Minutes the cycle ends with if the current pace holds; nil while the cycle is too young to tell.
    var projectedMinutes: Double? {
        let elapsed = now.timeIntervalSince(cycle.start)
        guard elapsed >= Self.minimumElapsedForPace else { return nil }
        return usedMinutes / elapsed * cycle.duration
    }

    /// When the quota runs out at the current pace, if it does before the reset.
    var exhaustionDate: Date? {
        guard usedMinutes < quotaMinutes else { return now }
        guard let projectedMinutes, projectedMinutes > quotaMinutes else { return nil }
        let minutesPerSecond = usedMinutes / now.timeIntervalSince(cycle.start)
        return now.addingTimeInterval((quotaMinutes - usedMinutes) / minutesPerSecond)
    }
}

nonisolated enum UsageCalculator {
    private struct UsageEntry {
        var product: String
        var date: Date
        var billedMinutes: Double = 0
        var estimatedMinutes: Double = 0
        var workflow: String?
        var buildNumber: Int?
    }

    static func summary(
        snapshot: BuildSnapshot,
        ledger: UsageLedger,
        plan: UsagePlan,
        now: Date,
        calendar: Calendar = .current
    ) -> UsageSummary {
        let productNames = Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ratios = WorkflowRatios(snapshot: snapshot, ledger: ledger, productNames: productNames, now: now)

        var entries = ledger.builds.values.map {
            UsageEntry(product: $0.product, date: $0.startedAt, billedMinutes: Double($0.minutes), workflow: $0.workflow, buildNumber: $0.buildNumber)
        }
        var estimatedRunIDs: Set<String> = []
        var builds: [String: Date] = Dictionary(ledger.builds.values.map { ($0.key, $0.startedAt) }, uniquingKeysWith: { first, _ in first })
        for run in snapshot.runs {
            let product = productNames[run.productID] ?? run.productID
            guard let number = run.number, let created = run.createdDate else { continue }
            if builds["\(product)#\(number)"] == nil {
                builds["\(product)#\(number)"] = created
            }
            guard ledger.billedBuild(product: product, buildNumber: number) == nil else { continue }
            // A build whose test results are still on their way has no honest estimate yet: it waits for them.
            guard !(snapshot.actionsByRunID[run.id] ?? []).contains(where: snapshot.needsTestResults) else { continue }
            let actionMinutes = actionMinutes(of: run, in: snapshot, now: now)
            entries.append(UsageEntry(
                product: product, date: created, estimatedMinutes: actionMinutes * ratios.ratio(product: product, workflow: run.workflowName),
                workflow: run.workflowName, buildNumber: number
            ))
            estimatedRunIDs.insert(run.id)
        }

        let cycle = plan.cycle(containing: now, calendar: calendar)
        let inCycle = entries.filter { cycle.contains($0.date) && $0.date <= now }

        let today = calendar.startOfDay(for: now)
        var daily: [DailyUsage] = (0..<30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DailyUsage(day: $0) }
        }
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            guard let index = daily.firstIndex(where: { $0.day == day }) else { continue }
            daily[index].billedMinutes += entry.billedMinutes
            daily[index].estimatedMinutes += entry.estimatedMinutes
        }
        let windowStart = daily.first?.day ?? today

        var byApp: [String: AppUsage] = [:]
        for entry in inCycle {
            byApp[entry.product, default: AppUsage(product: entry.product)].billedMinutes += entry.billedMinutes
            byApp[entry.product, default: AppUsage(product: entry.product)].estimatedMinutes += entry.estimatedMinutes
        }

        var workflows: [String: WorkflowUsage] = [:]
        var costliest: BuildCost?
        for entry in inCycle {
            let name = entry.workflow ?? String(localized: "Other workflows")
            let key = "\(entry.product)|\(name)"
            var usage = workflows[key] ?? WorkflowUsage(product: entry.product, workflow: name)
            usage.billedMinutes += entry.billedMinutes
            usage.estimatedMinutes += entry.estimatedMinutes
            usage.buildCount += 1
            workflows[key] = usage
            if let number = entry.buildNumber, entry.billedMinutes + entry.estimatedMinutes > (costliest?.minutes ?? 0) {
                costliest = BuildCost(
                    product: entry.product, buildNumber: number, workflow: entry.workflow,
                    minutes: entry.billedMinutes + entry.estimatedMinutes, isEstimated: entry.billedMinutes == 0
                )
            }
        }

        var measurement = MeasurementProgress()
        for run in snapshot.runs {
            let product = productNames[run.productID] ?? run.productID
            guard let number = run.number, let created = run.createdDate, cycle.contains(created),
                  ledger.billedBuild(product: product, buildNumber: number) == nil
            else { continue }
            var pending = false
            var unmeasurable = false
            for action in snapshot.actionsByRunID[run.id] ?? [] where action.actionType == .test && action.executionProgress == .complete {
                measurement.totalActions += 1
                if snapshot.testDevicesByActionID[action.id] != nil {
                    measurement.measuredActions += 1
                } else if snapshot.needsTestResults(action) {
                    pending = true
                } else {
                    measurement.unmeasurableActions += 1
                    unmeasurable = true
                }
            }
            if pending { measurement.pendingBuilds += 1 } else if unmeasurable { measurement.unmeasurableBuilds += 1 }
        }

        return UsageSummary(
            plan: plan,
            cycle: cycle,
            now: now,
            billedMinutes: inCycle.reduce(0) { $0 + $1.billedMinutes },
            estimatedMinutes: inCycle.reduce(0) { $0 + $1.estimatedMinutes },
            estimatedBuildCount: snapshot.runs.filter { estimatedRunIDs.contains($0.id) && ($0.createdDate.map(cycle.contains) ?? false) }.count,
            lastImport: ledger.lastImport,
            daily: daily,
            buildsLast30Days: builds.values.filter { $0 >= windowStart && $0 <= now }.count,
            byApp: byApp.values.sorted { $0.totalMinutes > $1.totalMinutes },
            measurement: measurement,
            byWorkflow: workflows.values.sorted { ($0.totalMinutes, $1.workflow) > ($1.totalMinutes, $0.workflow) },
            costliestBuild: costliest
        )
    }

    /// Machine minutes: each test device for its own time, other actions for their wall clock.
    static func actionMinutes(of run: CIBuildRun, in snapshot: BuildSnapshot, now: Date) -> Double {
        UsageEstimator.machineSeconds(of: run, in: snapshot, now: now) / 60
    }
}

/// Billed minutes per minute of action time, learned from builds present in both the exports and the API.
nonisolated struct WorkflowRatios: Sendable {
    private static let minimumActionMinutes = 1.0

    private var byWorkflow: [String: Double] = [:]
    private var global: Double?

    init(snapshot: BuildSnapshot, ledger: UsageLedger, productNames: [String: String], now: Date) {
        var sums: [String: (billed: Double, actions: Double)] = [:]
        var total = (billed: 0.0, actions: 0.0)
        for run in snapshot.runs where run.executionProgress == .complete {
            let product = productNames[run.productID] ?? run.productID
            guard let number = run.number, let billed = ledger.billedBuild(product: product, buildNumber: number) else { continue }
            let actions = UsageCalculator.actionMinutes(of: run, in: snapshot, now: now)
            let key = Self.key(product: product, workflow: run.workflowName)
            sums[key, default: (0, 0)].billed += Double(billed.minutes)
            sums[key, default: (0, 0)].actions += actions
            total.billed += Double(billed.minutes)
            total.actions += actions
        }
        byWorkflow = sums.compactMapValues { $0.actions >= Self.minimumActionMinutes ? $0.billed / $0.actions : nil }
        global = total.actions >= Self.minimumActionMinutes ? total.billed / total.actions : nil
    }

    func ratio(product: String, workflow: String?) -> Double {
        byWorkflow[Self.key(product: product, workflow: workflow)] ?? global ?? 1
    }

    private static func key(product: String, workflow: String?) -> String {
        "\(product)|\(workflow ?? "")"
    }
}
