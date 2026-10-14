import Foundation

/// What the “Slower since” card says: the slowdown, the build that starts it, and what it adds to the cycle.
nonisolated struct WorkflowSlowdownModel: Equatable, Sendable {
    /// What the slowdown adds, estimated from the minutes the builds cost.
    struct Extra: Equatable, Sendable {
        let perBuildMinutes: Double
        let cycleMinutes: Double
    }

    /// Below this, “about 0 min more” is not worth a line.
    static let minimumExtraMinutes = 1.0
    /// Builds of each level whose cost must be known for the difference to mean something.
    static let minimumCostedPerSide = 3

    let slowdown: WorkflowSlowdown
    let run: CIBuildRun
    let extra: Extra?

    var buildNumber: String? { run.number.map { "#\($0)" } }
    var shortSHA: String? { run.sourceCommit?.shortSha }

    /// The first line of the commit message.
    var commitTitle: String? {
        run.sourceCommit?.message?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var commitURL: URL? { WorkflowSlowdown.gitHubCommitURL(run.sourceCommit?.webURL) }
    var since: Date? { run.createdDate ?? run.startedDate }

    /// From the cache alone. `summary` is the usage of the shown account: nil without a plan, and while the first
    /// results are still being measured the cost line is left out.
    static func make(workflowID: String, snapshot: BuildSnapshot, ledger: UsageLedger, summary: UsageSummary?, now: Date) -> WorkflowSlowdownModel? {
        let runs = snapshot.runs.filter { $0.workflowID == workflowID }
        guard let slowdown = WorkflowSlowdown(runs: runs, actionsByRunID: snapshot.actionsByRunID),
              let run = runs.first(where: { $0.id == slowdown.buildID })
        else { return nil }
        return WorkflowSlowdownModel(
            slowdown: slowdown, run: run,
            extra: summary.flatMap { extra(of: slowdown, in: runs, snapshot: snapshot, ledger: ledger, summary: $0, now: now) }
        )
    }

    private static func extra(
        of slowdown: WorkflowSlowdown, in runs: [CIBuildRun], snapshot: BuildSnapshot, ledger: UsageLedger, summary: UsageSummary, now: Date
    ) -> Extra? {
        guard !summary.measurement.isMeasuring, let breakDate = runs.first(where: { $0.id == slowdown.buildID })?.createdDate else { return nil }
        let productNames = Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ratios = WorkflowRatios(snapshot: snapshot, ledger: ledger, productNames: productNames, now: now)
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func costs(_ ids: ArraySlice<String>) -> [Double] {
            // A build with no action to measure costs nothing by the estimate: that is a gap, not a cheap build.
            ids.compactMap { byID[$0] }.compactMap {
                UsageCalculator.cost(of: $0, in: snapshot, ledger: ledger, ratios: ratios, productNames: productNames, now: now)?.minutes
            }.filter { $0 > 0 }
        }
        let before = costs(slowdown.idsBefore)
        let after = costs(slowdown.idsAfter)
        guard before.count >= minimumCostedPerSide, after.count >= minimumCostedPerSide,
              let usual = WorkflowTrends.median(before), let slow = WorkflowTrends.median(after),
              slow - usual >= minimumExtraMinutes
        else { return nil }
        let slowBuilds = runs.filter { run in
            guard run.executionProgress == .complete, run.completionStatus != .canceled, run.completionStatus != .skipped,
                  let created = run.createdDate
            else { return false }
            return created >= breakDate && summary.cycle.contains(created)
        }
        return Extra(perBuildMinutes: slow - usual, cycleMinutes: (slow - usual) * Double(slowBuilds.count))
    }
}

/// The words of the card and of the banner.
nonisolated enum WorkflowSlowdownText {
    static func title(since date: Date?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else { return String(localized: "Slower lately", comment: "Title of the card that says a workflow got slower, when the date of the first slow build is unknown") }
        let day = date.formatted(.dateTime.day().month(.wide).locale(locale))
        return String(localized: "Slower since \(day)", comment: "Title of the card that says a workflow got slower. The placeholder is a date such as “October 7”.")
    }

    /// “18 min median, against 13 min before”
    static func headline(_ slowdown: WorkflowSlowdown, locale: Locale = .autoupdatingCurrent) -> String {
        String(
            localized: "\(duration(slowdown.medianAfter, locale: locale)) median, against \(duration(slowdown.medianBefore, locale: locale)) before",
            comment: "The median duration of a workflow since it got slower, then before. Both placeholders are durations such as “18 min”."
        )
    }

    static func increase(_ slowdown: WorkflowSlowdown, locale: Locale = .autoupdatingCurrent) -> String {
        slowdown.increase.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()).locale(locale))
    }

    /// “6 min → 11 min”
    static func change(_ change: WorkflowSlowdown.ActionChange, locale: Locale = .autoupdatingCurrent) -> String {
        String(
            localized: "\(duration(change.before, locale: locale)) → \(duration(change.after, locale: locale))",
            comment: "The median time of an action before, then after a workflow got slower. Keep the arrow."
        )
    }

    /// “+5 min”, only for an action that clearly changed.
    static func delta(_ change: WorkflowSlowdown.ActionChange, locale: Locale = .autoupdatingCurrent) -> String? {
        guard change.delta >= WorkflowSlowdown.minimumActionChange else { return nil }
        return "+" + duration(change.delta, locale: locale)
    }

    static func extraLine(_ extra: WorkflowSlowdownModel.Extra, locale: Locale = .autoupdatingCurrent) -> String {
        let perBuild = UsageFormat.minutes(extra.perBuildMinutes, locale: locale)
        let cycle = UsageFormat.minutes(extra.cycleMinutes, locale: locale)
        return String(
            localized: "~\(perBuild) more per build, ~\(cycle) over this cycle. Estimate.",
            comment: "What a slowdown adds to the compute hours. Both placeholders are durations. Keep the tildes: the figure is an estimate."
        )
    }

    static func bannerTitle(app: String, workflow: String, slowdown: WorkflowSlowdown, locale: Locale = .autoupdatingCurrent) -> String {
        let percent = UsageFormat.percent(slowdown.increase, locale: locale)
        return String(
            localized: "\(app) · \(workflow) slowed down by \(percent)",
            comment: "Notification title: app name, workflow name, then how much longer its builds take."
        )
    }

    static func bannerBody(build: String?, since date: Date, slowdown: WorkflowSlowdown, locale: Locale = .autoupdatingCurrent) -> String {
        let from = build ?? String(localized: "a build", comment: "A build whose number is unknown, in “Since a build, October 7”")
        let day = date.formatted(.dateTime.day().month(.wide).locale(locale))
        if let action = slowdown.mainAction {
            return String(
                localized: "Since \(from), \(day): \(action.name) went from \(duration(action.before, locale: locale)) to \(duration(action.after, locale: locale)).",
                comment: "Notification body: the build, the date, the action that slowed down most, then its median before and after."
            )
        }
        return String(
            localized: "Since \(from), \(day): median from \(duration(slowdown.medianBefore, locale: locale)) to \(duration(slowdown.medianAfter, locale: locale)).",
            comment: "Notification body: the build, the date, then the median duration of the workflow before and after."
        )
    }

    /// Seconds under a minute, otherwise whole minutes.
    static func duration(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        guard seconds < 60 else { return UsageFormat.minutes(seconds / 60, locale: locale) }
        return Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.seconds], width: .abbreviated).locale(locale))
    }
}
