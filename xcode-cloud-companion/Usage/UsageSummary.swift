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
            UsageEntry(product: $0.product, date: $0.startedAt, billedMinutes: Double($0.minutes))
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
            let actionMinutes = actionMinutes(of: run, in: snapshot, now: now)
            entries.append(UsageEntry(product: product, date: created, estimatedMinutes: actionMinutes * ratios.ratio(product: product, workflow: run.workflowName)))
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
            byApp: byApp.values.sorted { $0.totalMinutes > $1.totalMinutes }
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
