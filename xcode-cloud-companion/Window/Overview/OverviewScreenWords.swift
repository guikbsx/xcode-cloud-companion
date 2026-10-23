import Foundation

/// The sentences of the Overview's screen other than the headline and the small notes (those are `OverviewHeadlineWords`):
/// the account line, the figure's caption, legend and columns, and what VoiceOver says of a row.
nonisolated struct OverviewScreenWords: Sendable {
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .current

    private var headline: OverviewHeadlineWords { OverviewHeadlineWords(locale: locale, calendar: calendar) }

    // MARK: Figures

    /// “Thursday, October 23”, its first letter in capitals: some languages write weekdays and months in lower case.
    func longDay(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.locale = locale
        style.timeZone = calendar.timeZone
        let text = date.formatted(style)
        return text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }

    /// “22 Sep”, over the Monday that starts a week of the mosaic.
    func weekStart(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// “M”, over a day of the mosaic.
    func weekdayInitial(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.narrow)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    func time(_ date: Date) -> String { headline.time(date) }

    // MARK: Account line

    /// “Brioche #412”
    func buildName(app: String?, number: Int?) -> String {
        [app.flatMap { $0.isEmpty ? nil : $0 }, number.map { "#\($0)" }].compactMap(\.self).joined(separator: " ")
    }

    func runningLine(build: String, end: Date?, left: BuildETA.Display?) -> String {
        guard let end, let left else {
            return String(localized: LocalizedStringResource("\(build) is running", locale: locale, comment: "In the line at the top of the Overview: a build is running and no end can be estimated. The placeholder is the build, such as “Brioche #412”."))
        }
        let time = time(end)
        let remaining = BuildETAFormat.approximate(left, locale: locale)
        return String(localized: LocalizedStringResource(
            "\(build) is running, ends around \(time) (\(remaining))", locale: locale,
            comment: "In the line at the top of the Overview: a build is running. The placeholders are the build such as “Brioche #412”, a time such as “2:36 PM” and the time left such as “~4 min”."
        ))
    }

    func queuedLine(build: String) -> String {
        String(localized: LocalizedStringResource("\(build) is waiting in the queue", locale: locale, comment: "In the line at the top of the Overview: a build is queued at Apple. The placeholder is the build, such as “Brioche #412”."))
    }

    func andMore(_ line: String, count: Int) -> String {
        String(localized: LocalizedStringResource("\(line), and \(count) more", locale: locale, comment: "In the line at the top of the Overview: the first running build, then how many others run or wait. The placeholders are the first part of the line and a number."))
    }

    func runningAccessibility(_ line: String) -> String {
        String(localized: LocalizedStringResource("\(line). Opens the build.", locale: locale, comment: "VoiceOver label of the running build in the line at the top of the Overview. The placeholder is the line."))
    }

    func planAccessibility(used: String, quota: String, isEstimate: Bool) -> String {
        guard isEstimate else {
            return String(localized: LocalizedStringResource("Plan: \(used) of \(quota)", locale: locale, comment: "VoiceOver label of the plan in the line at the top of the Overview. The placeholders are the minutes used and the plan, such as “17 hr 40 min” and “25 hr”."))
        }
        return String(localized: LocalizedStringResource("Plan: about \(used) of \(quota), estimated", locale: locale, comment: "VoiceOver label of the plan in the line at the top of the Overview when the minutes are an estimate. The placeholders are the minutes used and the plan."))
    }

    // MARK: Empty and reading

    func emptyTitle(days: Int) -> String {
        String(localized: LocalizedStringResource(
            "**No build** in the last \(days) days.", locale: locale,
            comment: "Headline of the Overview when the account has no build in the period the mosaic covers. Put the words for “No build” between the double asterisks, which are not shown. The placeholder is a number of days."
        ))
    }

    func emptyLine() -> String {
        String(localized: LocalizedStringResource("Builds appear here as soon as a workflow runs.", locale: locale, comment: "Under the headline of the Overview when the account has no recent build"))
    }

    // MARK: Row

    /// What VoiceOver reads for a row of the mosaic, which stands for its whole row of squares:
    /// “Sextant, Nightly: failing for three days, 57 % succeeded over 7 days, 18 min median”.
    func rowSummary(app: String, row: OverviewMosaic.Row, now: Date) -> String {
        let name = String(localized: LocalizedStringResource("\(app), \(row.name)", locale: locale, comment: "VoiceOver: an app and one of its workflows, such as “Sextant, Nightly”"))
        var facts: [String] = []
        if row.isPaused {
            facts.append(String(localized: LocalizedStringResource("paused", locale: locale, comment: "VoiceOver, about a workflow of the Overview: it is paused")))
        } else if let series = row.failureSeries {
            let span = series.firstDate.map { headline.span(since: $0, now: now) }
            facts.append(span.map {
                String(localized: LocalizedStringResource("failing \($0)", locale: locale, comment: "VoiceOver, about a workflow of the Overview. The placeholder is how long, such as “for three days” or “since yesterday”."))
            } ?? String(localized: LocalizedStringResource("failing", locale: locale, comment: "VoiceOver, about a workflow of the Overview: its latest builds fail")))
        } else {
            facts.append(String(localized: LocalizedStringResource("passing", locale: locale, comment: "VoiceOver, about a workflow of the Overview: its latest build succeeded")))
        }
        if let rate = row.successRate {
            let percent = headline.percent(rate)
            facts.append(String(localized: LocalizedStringResource("\(percent) succeeded over 7 days", locale: locale, comment: "VoiceOver, about a workflow of the Overview. The placeholder is a percentage.")))
        }
        if let median = row.medianSeconds {
            let length = headline.duration(median)
            facts.append(String(localized: LocalizedStringResource("\(length) median", locale: locale, comment: "VoiceOver, about a workflow of the Overview: its median build time. The placeholder is a duration such as “18 min”.")))
        }
        if let cycle = row.cycle, cycle.minutes > 0 {
            let length = UsageFormat.minutes(cycle.minutes, locale: locale)
            facts.append(cycle.isEstimated
                ? String(localized: LocalizedStringResource("about \(length) of the cycle", locale: locale, comment: "VoiceOver, about a workflow of the Overview: the minutes it used this cycle, estimated. The placeholder is a duration."))
                : String(localized: LocalizedStringResource("\(length) of the cycle", locale: locale, comment: "VoiceOver, about a workflow of the Overview: the minutes it used this cycle. The placeholder is a duration.")))
        }
        return String(localized: LocalizedStringResource("\(name): \(facts.joined(separator: ", "))", locale: locale, comment: "VoiceOver reading of a row of the Overview's mosaic. The placeholders are the workflow and its facts."))
    }
}
