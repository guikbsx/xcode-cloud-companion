import Foundation

/// Plain-text comparison sheet for checking the estimate against App Store Connect's own figures.
nonisolated enum UsageDiagnostic {
    struct Period: Sendable {
        let title: String
        let interval: DateInterval
    }

    static func periods(plan: UsagePlan?, now: Date, calendar: Calendar) -> [Period] {
        let today = calendar.startOfDay(for: now)
        var periods: [Period] = []
        for days in [31, 30] {
            guard let start = calendar.date(byAdding: .day, value: -days, to: today),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: today)
            else { continue }
            periods.append(Period(
                title: "\(day(start, calendar)) – \(day(lastDay, calendar)) (\(days) days)",
                interval: DateInterval(start: start, end: today)
            ))
        }
        if let plan {
            let cycle = plan.cycle(containing: now, calendar: calendar)
            periods.append(Period(
                title: "Current cycle, since \(moment(cycle.start, calendar))",
                interval: DateInterval(start: cycle.start, end: max(cycle.start, now))
            ))
        }
        return periods
    }

    struct SyncState: Sendable {
        var isConfigured: Bool
        var isSyncing: Bool
        var progress: String?
        var lastError: AppStoreConnectError?
    }

    static func report(snapshot: BuildSnapshot, plan: UsagePlan?, syncState: SyncState? = nil, now: Date, calendar: Calendar = .current) -> String {
        var lines: [String] = []
        lines.append("Xcode Cloud usage diagnostic — \(moment(now, calendar)) (\(calendar.timeZone.identifier))")
        if let syncState {
            lines.append("API key: \(syncState.isConfigured ? "configured" : "not configured (or not read yet)")")
            lines.append("Sync: \(syncState.isSyncing ? "in progress — \(syncState.progress ?? "")" : "idle")")
            let pending = BuildSynchronizer.pendingTestResultCount(in: snapshot)
            lines.append("Test results still to fetch: \(pending) action\(pending == 1 ? "" : "s")")
            lines.append("Last error: \(syncState.lastError.map { "\($0) — \($0.message)" } ?? "none")")
        }
        lines.append("Last sync: \(snapshot.lastSuccessfulSync.map { moment($0, calendar) } ?? "never")")
        let created = snapshot.runs.compactMap(\.createdDate)
        if let oldest = created.min(), let newest = created.max() {
            lines.append("Builds in cache: \(snapshot.runs.count), created \(moment(oldest, calendar)) – \(moment(newest, calendar))")
        } else {
            lines.append("Builds in cache: 0")
        }
        if let plan {
            lines.append("Plan: \(plan.hours) h, next reset \(moment(plan.nextReset(after: now, calendar: calendar), calendar))")
        } else {
            lines.append("Plan: reset date not set in Settings")
        }

        let periods = periods(plan: plan, now: now, calendar: calendar)
        lines.append("")
        lines.append(row("Period", "Builds", "Build runs", "Actions", "Actions ↑min", "Machine", firstWidth: 44))
        for period in periods {
            let totals = UsageEstimator.totals(of: snapshot, in: period.interval, now: now)
            lines.append(row(period.title, totals, firstWidth: 44))
        }

        if let reference = periods.first {
            lines.append("")
            lines.append("By completion status, \(reference.title)")
            let statuses = Set(snapshot.runs.map { $0.completionStatus?.rawValue ?? "IN PROGRESS" }).sorted()
            for status in statuses {
                let totals = UsageEstimator.totals(of: snapshot, in: reference.interval, now: now) {
                    ($0.completionStatus?.rawValue ?? "IN PROGRESS") == status
                }
                if totals.buildCount > 0 { lines.append(row(status, totals, firstWidth: 20)) }
            }

            lines.append("")
            lines.append("By action type, \(reference.title)")
            let referenceTotals = UsageEstimator.totals(of: snapshot, in: reference.interval, now: now)
            for type in referenceTotals.actionSecondsByType.keys.sorted() {
                lines.append(row(
                    type,
                    "\(referenceTotals.actionCountByType[type] ?? 0) actions",
                    hoursAndMinutes(referenceTotals.actionSecondsByType[type] ?? 0),
                    firstWidth: 20
                ))
            }

            let types = ["BUILD", "ANALYZE", "TEST", "ARCHIVE"]
            lines.append("")
            lines.append("Per day, \(reference.title)")
            lines.append(row("Day", ["Builds", "Build runs", "Actions", "Actions ↑min", "Machine"] + types.map { "\($0.capitalized) acts" }, firstWidth: 20))
            var dayStart = reference.interval.start
            while dayStart < reference.interval.end, let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) {
                let totals = UsageEstimator.totals(of: snapshot, in: DateInterval(start: dayStart, end: dayEnd), now: now)
                let byType = types.map { hoursAndMinutes(totals.actionSecondsByType[$0] ?? 0) }
                lines.append(row(day(dayStart, calendar), columns(totals) + byType, firstWidth: 20))
                dayStart = dayEnd
            }
        }
        lines.append("")
        if !snapshot.workflows.isEmpty {
            lines.append("")
            lines.append("Workflows (test destinations configured today)")
            for workflow in snapshot.workflows {
                lines.append("  \(workflow.name): \(workflow.testDestinationCounts.isEmpty ? "no test action" : workflow.testDestinationCounts.map(String.init).joined(separator: " + ") + " destinations")")
            }
        }

        lines.append("")
        lines.append("Per build (number ; product ; workflow ; created UTC ; status ; run min ; MACHINE min ; test devices: N, Σ device min, wall min ; actions: TYPE minutes…)")
        let productNames = Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for run in snapshot.runs.sorted(by: { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }) {
            let actions = (snapshot.actionsByRunID[run.id] ?? []).map { action in
                let minutes = UsageEstimator.duration(from: action.startedDate, to: action.finishedDate, now: now) / 60
                let status = action.completionStatus?.rawValue ?? "-"
                return "\(action.actionType?.rawValue ?? "?") \(String(format: "%.1f", minutes)) \(status) [\(action.name ?? "")]"
            }
            let runMinutes = UsageEstimator.duration(from: run.startedDate, to: run.finishedDate, now: now) / 60
            let machineMinutes = UsageEstimator.machineSeconds(of: run, in: snapshot, now: now) / 60
            let devices = UsageEstimator.testDeviceBreakdown(of: run, in: snapshot, now: now)
            let deviceColumn = devices.actionsWithoutResults > 0 && devices.deviceCount == 0
                ? "no results"
                : "\(devices.deviceCount) dev, \(String(format: "%.1f", devices.deviceSeconds / 60)) dev-min, \(String(format: "%.1f", devices.wallClockSeconds / 60)) wall"
            lines.append([
                "#\(run.number.map(String.init) ?? "?")",
                productNames[run.productID] ?? run.productID,
                run.workflowName ?? "?",
                run.createdDate?.formatted(.iso8601) ?? "?",
                run.completionStatus?.rawValue ?? "IN PROGRESS",
                String(format: "%.1f", runMinutes),
                "MACHINE " + String(format: "%.1f", machineMinutes),
                deviceColumn,
                actions.joined(separator: " | "),
            ].joined(separator: " ; "))
            for action in snapshot.actionsByRunID[run.id] ?? [] {
                for device in snapshot.testDevicesByActionID[action.id] ?? [] {
                    lines.append("      \(device.deviceName) (\(device.osVersion)): \(String(format: "%.1f", device.totalSeconds / 60)) min, \(device.testCount) tests, \(device.failedCount) failed")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func hoursAndMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    private static func columns(_ totals: UsageTotals) -> [String] {
        [
            String(totals.buildCount),
            hoursAndMinutes(totals.seconds(.buildRunDuration)),
            hoursAndMinutes(totals.seconds(.actionDuration)),
            hoursAndMinutes(totals.seconds(.actionDurationRoundedUpToMinute)),
            hoursAndMinutes(totals.seconds(.machineMinutes)),
        ]
    }

    private static func row(_ title: String, _ totals: UsageTotals, firstWidth: Int) -> String {
        row(title, columns(totals), firstWidth: firstWidth)
    }

    private static func row(_ first: String, _ columns: String..., firstWidth: Int) -> String {
        row(first, columns, firstWidth: firstWidth)
    }

    private static func row(_ first: String, _ columns: [String], firstWidth: Int) -> String {
        first.padding(toLength: firstWidth, withPad: " ", startingAt: 0)
            + columns.map { String(repeating: " ", count: max(0, 14 - $0.count)) + $0 }.joined()
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, calendar: calendar, timeZone: calendar.timeZone).year().month(.twoDigits).day(.twoDigits))
    }

    private static func moment(_ date: Date, _ calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }
}
