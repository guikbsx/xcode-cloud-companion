import Foundation

/// What the bubble of a mosaic cell says: one day of one workflow. Worked out from the snapshot and what is already in
/// memory, with no request, no disk read and no model; the view only draws it.
///
/// The counts are the cell's own, so the sentence always agrees with the colour of the square; the lines are the builds
/// the cell counted (a build belongs to the day it was created on, like in `OverviewMosaic`).
nonisolated struct OverviewDayDetail: Equatable, Sendable {
    /// Lines shown before “and 3 more”.
    static let maximumLines = 8

    /// What a build of the day is doing or how it ended.
    enum State: Equatable, Sendable {
        case queued
        case running
        case finished
    }

    struct Line: Identifiable, Equatable, Sendable {
        let runID: String
        let number: Int?
        let status: BuildStatus
        let state: State
        /// When the build started; nil while it waits in the queue, or when Apple gave no start.
        let start: Date?
        /// Of a build that finished, started and ended; nil otherwise.
        let duration: TimeInterval?
        /// Of a failed build, when its category is already known.
        let category: FailureCategory?

        var id: String { runID }
    }

    /// The sentence of “In brief” for a failed build of the day.
    struct Insight: Equatable, Sendable {
        let runID: String
        let number: Int?
        let text: String
    }

    /// The start of the day.
    let day: Date
    let workflowID: String
    let workflowName: String
    let appName: String
    /// The cell, for the colour of the square and the sentence.
    let cell: OverviewMosaic.Cell
    /// Newest first, at most `maximumLines`.
    let lines: [Line]
    /// Builds of the day beyond the lines.
    let hiddenCount: Int
    /// The build the “Open” button opens: the newest of the day. A day with several builds also has a button per line.
    let openRunID: String?
    let openNumber: Int?
    /// The newest failed build of the day that has a sentence in memory.
    let insight: Insight?

    var isEmpty: Bool { cell.builds == 0 }

    /// - Parameters:
    ///   - row: the row of the mosaic the cell belongs to, and `appName` the name shown for its app.
    ///   - categories: the categories of failed builds already read, by build ID; `FailureInsightStore` keeps them.
    ///   - insights: the sentences of “In brief” already read, by build ID, and only when that function is open: this
    ///     never asks for one. A sentence of a build that did not fail is ignored.
    /// - Returns: nil when `day` is not a column of the row.
    init?(
        day: Date, row: OverviewMosaic.Row, appName: String, snapshot: BuildSnapshot, now: Date, calendar: Calendar = .current,
        categories: [String: FailureCategory] = [:], insights: [String: String] = [:]
    ) {
        let start = calendar.startOfDay(for: day)
        guard let cell = row.cells.first(where: { $0.day == start }) else { return nil }
        self.day = start
        self.cell = cell
        workflowID = row.workflowID
        workflowName = row.name
        self.appName = appName

        let runs = snapshot.runs
            .filter { $0.workflowID == row.workflowID }
            .filter { run in
                guard let date = run.createdDate ?? run.startedDate, date <= now else { return false }
                return calendar.startOfDay(for: date) == start
            }
            .sorted { Self.isNewer($0, than: $1) }

        let lines = runs.map { run -> Line in
            let status = BuildStatus(run: run)
            let duration: TimeInterval? = {
                guard run.executionProgress == .complete, let started = run.startedDate, let finished = run.finishedDate, finished >= started else { return nil }
                return finished.timeIntervalSince(started)
            }()
            let isFailure = status == .failed || status == .errored
            return Line(
                runID: run.id, number: run.number, status: status,
                state: run.executionProgress == .pending ? .queued : status == .running ? .running : .finished,
                start: run.startedDate, duration: duration, category: isFailure ? categories[run.id] : nil
            )
        }
        self.lines = Array(lines.prefix(Self.maximumLines))
        hiddenCount = max(lines.count - Self.maximumLines, 0)
        openRunID = runs.first?.id
        openNumber = runs.first?.number
        insight = runs.first(where: { run in
            let status = BuildStatus(run: run)
            return (status == .failed || status == .errored) && insights[run.id]?.isEmpty == false
        }).flatMap { run in insights[run.id].map { Insight(runID: run.id, number: run.number, text: $0) } }
    }

    private static func isNewer(_ lhs: CIBuildRun, than rhs: CIBuildRun) -> Bool {
        let left = (lhs.createdDate ?? lhs.startedDate ?? .distantPast, lhs.number ?? 0)
        let right = (rhs.createdDate ?? rhs.startedDate ?? .distantPast, rhs.number ?? 0)
        return left > right
    }
}

/// The sentences of the bubble.
nonisolated struct OverviewDayWords: Sendable {
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .current

    /// “Tuesday, October 21”, its first letter in capitals: some languages write weekdays and months in lower case.
    func longDay(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.locale = locale
        style.timeZone = calendar.timeZone
        let text = date.formatted(style)
        return text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// “Sextant · Nightly”
    func workflowLine(_ detail: OverviewDayDetail) -> String {
        UsageFormat.dotted([detail.appName, detail.workflowName], locale: locale)
    }

    /// “1 build, failed”, “3 builds, 1 failure”, “2 builds, all succeeded”, “No build that day”. The singular and the plural
    /// are separate entries: the number of builds is one only when a single build ran, and the failures are counted aside.
    func summary(_ cell: OverviewMosaic.Cell) -> String {
        let total = cell.builds
        let active = cell.running + cell.queued
        switch total {
        case 0:
            return String(localized: LocalizedStringResource("No build that day", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: the workflow had no build on that day."))
        case 1:
            if cell.failed == 1 { return String(localized: LocalizedStringResource("1 build, failed", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: the only build of the day failed.")) }
            if cell.succeeded == 1 { return String(localized: LocalizedStringResource("1 build, succeeded", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: the only build of the day succeeded.")) }
            if active == 1 { return String(localized: LocalizedStringResource("1 build, in progress", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: the only build of the day is running or waiting in the queue.")) }
            return String(localized: LocalizedStringResource("1 build, not finished", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: the only build of the day was canceled or skipped."))
        default:
            if cell.failed == total {
                return String(localized: LocalizedStringResource("\(total) builds, all failed", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: every build of the day failed. The placeholder is the number of builds, two or more."))
            }
            if cell.succeeded == total {
                return String(localized: LocalizedStringResource("\(total) builds, all succeeded", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: every build of the day succeeded. The placeholder is the number of builds, two or more."))
            }
            if cell.failed == 1 {
                return String(localized: LocalizedStringResource("\(total) builds, 1 failure", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: one build of the day failed, the others did not. The placeholder is the number of builds, two or more."))
            }
            if cell.failed > 1 {
                return String(localized: LocalizedStringResource("\(total) builds, \(cell.failed) failures", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: several builds of the day failed, others did not. The placeholders are the number of builds and the number that failed, both two or more."))
            }
            if active > 0 {
                return String(localized: LocalizedStringResource("\(total) builds, \(active) in progress", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: some builds are running or waiting in the queue, none failed. The placeholders are the number of builds (two or more) and the number in progress."))
            }
            if cell.succeeded > 0 {
                return String(localized: LocalizedStringResource("\(total) builds, \(cell.succeeded) succeeded", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: some builds succeeded and the others were canceled or skipped. The placeholders are the number of builds (two or more) and the number that succeeded."))
            }
            return String(localized: LocalizedStringResource("\(total) builds, none finished", locale: locale, comment: "In the bubble of a day of the Overview's mosaic: every build of the day was canceled or skipped. The placeholder is the number of builds, two or more."))
        }
    }

    /// “45 sec”, “18 min”, “1 hr 5 min”
    func duration(_ seconds: TimeInterval) -> String {
        WorkflowSlowdownText.duration(seconds, locale: locale)
    }

    /// “#203 · 02:00 · 18 min · Tests”: the state in words stands where the duration would be for a build that has none.
    func line(_ line: OverviewDayDetail.Line) -> String {
        var parts: [String] = []
        if let number = line.number { parts.append("#\(number)") }
        if let start = line.start { parts.append(time(start)) }
        parts.append(line.duration.map(duration) ?? stateWord(line))
        if let category = line.category { parts.append(category.displayName) }
        return UsageFormat.dotted(parts, locale: locale)
    }

    /// What VoiceOver reads for a line: the state first, since the dot says it only by colour and shape.
    func spokenLine(_ line: OverviewDayDetail.Line) -> String {
        let state = stateWord(line)
        return String(localized: LocalizedStringResource("\(state), \(self.line(line))", locale: locale, comment: "VoiceOver label of a build line in the bubble of a day of the Overview. The placeholders are the state such as “Failed” and the line such as “#203 · 02:00 · 18 min · Tests”."))
    }

    /// The state in words, for a build that has no duration to say.
    private func stateWord(_ line: OverviewDayDetail.Line) -> String {
        switch line.state {
        case .queued: String(localized: LocalizedStringResource("Queued", locale: locale, comment: "In a line of the bubble of a day of the Overview: the build waits in the queue. Very short."))
        case .running: Self.statusWord(.running, locale: locale)
        case .finished: Self.statusWord(line.status, locale: locale)
        }
    }

    func andMore(_ count: Int) -> String {
        String(localized: LocalizedStringResource("and \(count) more", locale: locale, comment: "At the foot of the build lines in the bubble of a day of the Overview: how many builds are not listed."))
    }

    func insight(_ text: String) -> String {
        String(localized: LocalizedStringResource("“\(text)”", locale: locale, comment: "In the bubble of a day of the Overview: the sentence of “In brief” about a failed build, between quotation marks. Use the quotation marks of the language."))
    }

    func openLabel(number: Int?) -> String {
        guard let number else {
            return String(localized: LocalizedStringResource("Open build", locale: locale, comment: "Button in the bubble of a day of the Overview: opens the build, whose number is unknown."))
        }
        return String(localized: LocalizedStringResource("Open #\(number)", locale: locale, comment: "Button in the bubble of a day of the Overview: opens a build. The placeholder is its number, such as “203”."))
    }

    func seeDayLabel() -> String {
        String(localized: LocalizedStringResource("See the day", locale: locale, comment: "Button in the bubble of a day of the Overview: shows the list of the day's builds of this workflow."))
    }

    /// What VoiceOver reads first for the bubble: “Sextant · Nightly, Tuesday, October 21. 1 build, failed”.
    func spokenHeader(_ detail: OverviewDayDetail) -> String {
        let workflow = workflowLine(detail)
        let day = longDay(detail.day)
        let summary = summary(detail.cell)
        return String(localized: LocalizedStringResource("\(workflow), \(day). \(summary)", locale: locale, comment: "VoiceOver label of the bubble of a day of the Overview. The placeholders are the app and workflow such as “Sextant · Nightly”, the day such as “Tuesday, October 21” and the sentence such as “1 build, failed”."))
    }

    private static func statusWord(_ status: BuildStatus, locale: Locale) -> String {
        switch status {
        case .succeeded: String(localized: LocalizedStringResource("Succeeded", locale: locale))
        case .failed: String(localized: LocalizedStringResource("Failed", locale: locale))
        case .errored: String(localized: LocalizedStringResource("Error", locale: locale))
        case .canceled: String(localized: LocalizedStringResource("Canceled", locale: locale))
        case .skipped: String(localized: LocalizedStringResource("Skipped", locale: locale))
        case .running: String(localized: LocalizedStringResource("Running", locale: locale))
        case .finished: String(localized: LocalizedStringResource("Finished", locale: locale))
        }
    }
}
