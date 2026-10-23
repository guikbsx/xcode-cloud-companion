import Foundation

/// The curve of a workflow's drawer in the Overview: the median time of its successful builds, day by day, on the
/// columns of the mosaic, and the level change `WorkflowSlowdown` found, if any. Worked out from the snapshot alone.
///
/// Whether the drawer is open is Cumulus Pro's call (`ProFeature.workflowTrends`): this type does not ask.
nonisolated struct OverviewDurationSeries: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        /// The start of the day.
        let day: Date
        /// The median of the day's successful builds; nil without one: a gap in the curve, never a zero.
        let medianSeconds: TimeInterval?
        /// Successful builds with a duration that day.
        let builds: Int
    }

    /// The level change, with the build that starts the new level.
    struct Step: Equatable, Sendable {
        let runID: String
        let number: Int?
        /// When the build was created.
        let date: Date?
        /// The column of that day; nil when it falls before the first column.
        let column: Int?
        let medianBefore: TimeInterval
        let medianAfter: TimeInterval
        /// The median after over the median before, minus one: `0.38` is 38 % longer.
        let increase: Double
    }

    let workflowID: String
    let workflowName: String
    /// One per column of the mosaic, the oldest first.
    let points: [Point]
    /// Nil when no level change was found.
    let step: Step?
    let trend: OverviewMosaic.Trend

    var dayCount: Int { points.count }
    /// The longest daily median, for the scale of the curve; nil without a successful build.
    var maximumSeconds: TimeInterval? { points.compactMap(\.medianSeconds).max() }
    var minimumSeconds: TimeInterval? { points.compactMap(\.medianSeconds).min() }
    var hasData: Bool { maximumSeconds != nil }

    /// - Parameter row: the row of the mosaic: its columns are the curve's, and its trend is the one told when no
    ///   level change was found.
    init(row: OverviewMosaic.Row, snapshot: BuildSnapshot, now: Date, calendar: Calendar = .current) {
        workflowID = row.workflowID
        workflowName = row.name
        trend = row.trend
        let days = row.cells.map(\.day)
        let columns = Dictionary(days.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let runs = snapshot.runs.filter { $0.workflowID == row.workflowID }

        var durations = [[Double]](repeating: [], count: days.count)
        for run in runs where run.executionProgress == .complete && run.completionStatus == .succeeded {
            guard let created = run.createdDate ?? run.startedDate, created <= now,
                  let column = columns[calendar.startOfDay(for: created)],
                  let started = run.startedDate, let finished = run.finishedDate, finished >= started
            else { continue }
            durations[column].append(finished.timeIntervalSince(started))
        }
        points = zip(days, durations).map { day, values in
            Point(day: day, medianSeconds: WorkflowTrends.median(values), builds: values.count)
        }

        if let slowdown = WorkflowSlowdown(runs: runs, actionsByRunID: snapshot.actionsByRunID),
           let run = runs.first(where: { $0.id == slowdown.buildID }) {
            let date = run.createdDate ?? run.startedDate
            step = Step(
                runID: run.id, number: run.number, date: date, column: date.flatMap { columns[calendar.startOfDay(for: $0)] },
                medianBefore: slowdown.medianBefore, medianAfter: slowdown.medianAfter, increase: slowdown.increase
            )
        } else {
            step = nil
        }
    }
}

/// The words of the drawer.
nonisolated struct OverviewDurationWords: Sendable {
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .current

    /// “~8 min 40”, “~12 min”, “~45 sec”: to the nearest ten seconds, the seconds unit left out after the minutes.
    func approximate(_ seconds: TimeInterval) -> String {
        "~" + Self.fine(seconds, locale: locale)
    }

    static func fine(_ seconds: TimeInterval, locale: Locale) -> String {
        guard seconds >= 60 else { return WorkflowSlowdownText.duration(seconds, locale: locale) }
        guard seconds < 3_600 else { return UsageFormat.minutes(seconds / 60, locale: locale) }
        let tens = Int((seconds / 10).rounded()) * 10
        let minutes = tens / 60
        let rest = tens % 60
        let whole = Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .abbreviated).locale(locale))
        return rest == 0 ? whole : "\(whole) \(rest)"
    }

    /// “before: ~8 min 40”
    func beforeLine(_ step: OverviewDurationSeries.Step) -> String {
        let value = approximate(step.medianBefore)
        return String(localized: LocalizedStringResource("before: \(value)", locale: locale, comment: "In the drawer of a workflow in the Overview, under “Slowdown”: the median build time before it got slower. The placeholder is a duration such as “~8 min 40”. Keep the tilde."))
    }

    /// “since: ~12 min”
    func afterLine(_ step: OverviewDurationSeries.Step) -> String {
        let value = approximate(step.medianAfter)
        return String(localized: LocalizedStringResource("since: \(value)", locale: locale, comment: "In the drawer of a workflow in the Overview, under “Slowdown”: the median build time since it got slower. The placeholder is a duration such as “~12 min”. Keep the tilde."))
    }

    /// “+38 %”
    func increase(_ step: OverviewDurationSeries.Step) -> String {
        step.increase.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()).locale(locale))
    }

    /// “since Oct 7, #398”: the number is left out when Apple gave none, the date when it is unknown.
    func sinceLine(_ step: OverviewDurationSeries.Step) -> String? {
        switch (step.date.map(shortDay), step.number) {
        case let (day?, number?):
            return String(localized: LocalizedStringResource("since \(day), #\(number)", locale: locale, comment: "In the drawer of a workflow in the Overview, under “Slowdown”: the day and the number of the first build that was slower. The placeholders are a date such as “Oct 7” and a build number such as “398”."))
        case let (day?, nil):
            return String(localized: LocalizedStringResource("from \(day)", locale: locale, comment: "In the drawer of a workflow in the Overview, under “Slowdown”: the day of the first build that was slower, after a percentage such as “+38 %”. The placeholder is a date such as “Oct 7”."))
        case let (nil, number?):
            return String(localized: LocalizedStringResource("since #\(number)", locale: locale, comment: "In the drawer of a workflow in the Overview, under “Slowdown”: the number of the first build that was slower. The placeholder is a build number such as “398”."))
        case (nil, nil):
            return nil
        }
    }

    /// The label of the curve's small caption.
    func caption(days: Int) -> String {
        String(localized: LocalizedStringResource("Median time per day, \(days) days", locale: locale, comment: "Caption of the curve in the drawer of a workflow in the Overview. The placeholder is the number of days, such as 35."))
    }

    /// What VoiceOver says of the drawer: “Durations of Release – iOS over 35 days, up 38 % since October 7”.
    func spoken(_ series: OverviewDurationSeries) -> String {
        let workflow = series.workflowName
        let days = series.dayCount
        if let step = series.step {
            let percent = UsageFormat.percent(step.increase, locale: locale)
            if let date = step.date {
                let day = longDay(date)
                return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, up \(percent) since \(day)", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when it got slower. The placeholders are the workflow, a number of days, a percentage such as “38 %” and a date such as “October 7”."))
            }
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, up \(percent)", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when it got slower and the day is unknown. The placeholders are the workflow, a number of days and a percentage such as “38 %”."))
        }
        guard series.hasData else {
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, no successful build", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when no build succeeded in the period. The placeholders are the workflow and a number of days."))
        }
        let recent = OverviewMosaic.recentDays
        switch series.trend {
        case .unknown:
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview. The placeholders are the workflow and a number of days."))
        case .stable:
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, stable over the last \(recent) days", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when its median time did not move. The placeholders are the workflow and two numbers of days."))
        case .up(let fraction):
            let percent = UsageFormat.percent(abs(fraction), locale: locale)
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, up \(percent) over the last \(recent) days", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when its median time rose. The placeholders are the workflow, a number of days, a percentage and a number of days."))
        case .down(let fraction):
            let percent = UsageFormat.percent(abs(fraction), locale: locale)
            return String(localized: LocalizedStringResource("Durations of \(workflow) over \(days) days, down \(percent) over the last \(recent) days", locale: locale, comment: "VoiceOver label of the drawer of a workflow in the Overview when its median time fell. The placeholders are the workflow, a number of days, a percentage and a number of days."))
        }
    }

    private func shortDay(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private func longDay(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
