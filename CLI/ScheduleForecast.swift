import Foundation

/// When the scheduled workflows next start, and what they will cost before the cycle resets, from what the cache
/// holds: no request. Shared with the `cumulus` command.
nonisolated struct ScheduleForecast: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let workflowID: String
        let workflowName: String
        /// The Xcode Cloud product name, the key of the usage; `productName` is the one shown.
        let productKey: String?
        let productName: String?
        /// The branches the schedule builds, when it does not build them all.
        let source: String?
        let frequency: CIScheduleFrequency
        let nextRun: Date
        /// What one run costs, from the cycle's builds of this workflow; nil without one.
        let minutesPerRun: Double?
        /// How many times the schedule fires before the cycle resets; nil without a cycle.
        let runsUntilReset: Int?

        var id: String { workflowID }
    }

    let now: Date
    /// Soonest first.
    let entries: [Entry]
    /// Estimated minutes of every scheduled run until the cycle resets; nil without a cycle.
    let minutesUntilReset: Double?
    /// Some scheduled workflow has no build in the cycle to estimate from: the total is short of it.
    let hasUnestimatedRuns: Bool

    /// `usage` is the cycle's minutes by workflow, `cycleEnd` when it resets; nil for either means no plan is set.
    init(workflows: [CIWorkflow], products: [CIProduct], cycleEnd: Date?, usage: [WorkflowUsage], now: Date, calendar: Calendar = .current) {
        self.now = now
        let productsByID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = workflows
            .compactMap { workflow -> Entry? in
                guard workflow.isEnabled != false, let schedule = workflow.startConditions?.schedule,
                      let nextRun = Self.nextRun(of: schedule, after: now, calendar: calendar)
                else { return nil }
                let product = workflow.productID.flatMap { productsByID[$0] }
                let minutes = usage.first { $0.product == product?.name && $0.workflow == workflow.name }.flatMap { $0.buildCount > 0 ? $0.averageMinutes : nil }
                return Entry(
                    workflowID: workflow.id, workflowName: workflow.name, productKey: product?.name, productName: product?.displayName,
                    source: schedule.source.flatMap { $0.isAllMatch || $0.patterns.isEmpty ? nil : $0.patterns.joined(separator: ", ") },
                    frequency: schedule.frequency, nextRun: nextRun, minutesPerRun: minutes,
                    runsUntilReset: cycleEnd.map { Self.runs(of: schedule, after: now, until: $0, calendar: calendar) }
                )
            }
            .sorted { ($0.nextRun, $0.workflowName) < ($1.nextRun, $1.workflowName) }
        minutesUntilReset = cycleEnd == nil ? nil : entries.reduce(0) { $0 + ($1.minutesPerRun ?? 0) * Double($1.runsUntilReset ?? 0) }
        hasUnestimatedRuns = cycleEnd != nil && entries.contains { $0.minutesPerRun == nil && ($0.runsUntilReset ?? 0) > 0 }
    }

    /// The first start strictly after `now`, in the schedule's time zone.
    static func nextRun(of schedule: CISchedule, after now: Date, calendar: Calendar) -> Date? {
        var calendar = calendar
        if let id = schedule.timeZoneID, let zone = TimeZone(identifier: id) {
            calendar.timeZone = zone
        }
        switch schedule.frequency {
        case .hourly:
            return calendar.nextDate(after: now, matching: DateComponents(minute: schedule.minute), matchingPolicy: .nextTime)
        case .daily:
            return calendar.nextDate(after: now, matching: DateComponents(hour: schedule.hour, minute: schedule.minute), matchingPolicy: .nextTime)
        case .weekly:
            return schedule.weekdays
                .compactMap { calendar.nextDate(after: now, matching: DateComponents(hour: schedule.hour, minute: schedule.minute, weekday: $0), matchingPolicy: .nextTime) }
                .min()
        }
    }

    /// How many times the schedule fires after `now` and no later than `end`.
    static func runs(of schedule: CISchedule, after now: Date, until end: Date, calendar: Calendar, limit: Int = 2000) -> Int {
        var count = 0
        var cursor = now
        while count < limit, let next = nextRun(of: schedule, after: cursor, calendar: calendar), next <= end {
            count += 1
            cursor = next
        }
        return count
    }
}
