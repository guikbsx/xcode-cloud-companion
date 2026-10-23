import Foundation

/// Every sentence of the Overview's headline and small notes. A sentence is one catalog entry: a part to put forward is
/// wrapped in `**` inside it, so a language can move it. Figures and dates come formatted for `locale`, in the time zone
/// of `calendar`.
nonisolated struct OverviewHeadlineWords: Sendable {
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .current

    /// A sentence cut into the parts to write plainly and the parts to put forward.
    static func parts(of marked: String) -> [OverviewHeadline.Part] {
        marked.components(separatedBy: "**").enumerated().compactMap { index, text in
            text.isEmpty ? nil : OverviewHeadline.Part(text: text, isEmphasized: !index.isMultiple(of: 2))
        }
    }

    /// A name or a figure that reaches a sentence cannot open or close an emphasis.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    // MARK: Figures

    func day(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide)
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    func duration(_ seconds: TimeInterval) -> String {
        UsageFormat.minutes(seconds / 60, locale: locale)
    }

    func percent(_ fraction: Double) -> String {
        UsageFormat.percent(fraction, locale: locale)
    }

    /// “two” to “ten” in words, a figure beyond.
    func spelled(_ number: Int) -> String {
        guard (2...10).contains(number) else { return number.formatted(.number.locale(locale)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    private func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }

    private func name(_ text: String, _ build: Int?) -> String {
        build.map { "\(plain(text)) #\($0)" } ?? plain(text)
    }

    // MARK: Broken

    func brokenApps(count: Int) -> String {
        let number = capitalized(spelled(count))
        return String(localized: LocalizedStringResource(
            "\(number) apps are **broken**.", locale: locale,
            comment: "Headline of the Overview when workflows of several apps fail on their latest build. The placeholder is a number in words, such as “Two”. Put the word for “broken” between the double asterisks, which are not shown."
        ))
    }

    func brokenWorkflows(app: String) -> String {
        String(localized: LocalizedStringResource(
            "\(plain(app)) is **broken**.", locale: locale,
            comment: "Headline of the Overview when several workflows of one app fail on their latest build. The placeholder is the app’s name. Put the word for “broken” between the double asterisks, which are not shown."
        ))
    }

    func broken(app: String, since span: String?) -> String {
        guard let span else { return brokenWorkflows(app: app) }
        return String(localized: LocalizedStringResource(
            "\(plain(app)) has been **broken** \(span).", locale: locale,
            comment: "Headline of the Overview when a workflow fails on its latest builds. The first placeholder is the app’s name, the second how long, such as “since yesterday” or “for two days”. Put the word for “broken” between the double asterisks, which are not shown."
        ))
    }

    /// How long ago it started, in the largest word that is true.
    func span(since start: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 2 {
            let spelled = spelled(days)
            return String(localized: LocalizedStringResource("for \(spelled) days", locale: locale, comment: "How long a workflow has been failing, two days or more. The placeholder is a number in words, such as “two”."))
        }
        if days == 1 {
            return String(localized: LocalizedStringResource("since yesterday", locale: locale, comment: "How long a workflow has been failing: it started yesterday"))
        }
        let hours = Int(now.timeIntervalSince(start) / 3600)
        guard hours >= 1 else {
            return String(localized: LocalizedStringResource("for less than an hour", locale: locale, comment: "How long a workflow has been failing: under an hour"))
        }
        let length = Duration.seconds(hours * 3600).formatted(.units(allowed: [.hours], width: .abbreviated).locale(locale))
        return String(localized: LocalizedStringResource("for \(length)", locale: locale, comment: "How long a workflow has been failing, today. The placeholder is a number of hours, such as “3 hr”."))
    }

    /// “Nightly has failed since #203, three times in a row.”
    func failureLine(workflow: String, series: OverviewMosaic.FailureSeries) -> String {
        let last = series.lastNumber.map { "#\($0)" } ?? "?"
        guard series.failureCount > 1 else {
            return String(localized: LocalizedStringResource(
                "\(plain(workflow)) failed on \(last).", locale: locale,
                comment: "Says a workflow failed on its latest build. The placeholders are the workflow’s name and a build number such as “#205”."
            ))
        }
        let first = series.firstNumber.map { "#\($0)" } ?? "?"
        let times = spelled(series.failureCount)
        return String(localized: LocalizedStringResource(
            "\(plain(workflow)) has failed since \(first), \(times) times in a row.", locale: locale,
            comment: "Says a workflow keeps failing. The placeholders are the workflow’s name, the build number of its first failure such as “#203”, and a number of times in words, such as “three”."
        ))
    }

    func openBuild(number: Int?) -> String {
        guard let number else {
            return String(localized: LocalizedStringResource("Open the build", locale: locale, comment: "Button on the Overview’s headline: opens the build it talks about"))
        }
        return String(localized: LocalizedStringResource("Open #\(number)", locale: locale, comment: "Button on the Overview’s headline: opens a build. The placeholder is its number."))
    }

    func copyForAI() -> String {
        String(localized: LocalizedStringResource("Copy for an AI", locale: locale, comment: "Button on the Overview’s headline: copies a failed build as text for an AI assistant"))
    }

    func openStatusPage() -> String {
        String(localized: LocalizedStringResource("See the status page", locale: locale, comment: "Button on the Overview’s headline: opens Apple’s system status page"))
    }

    func openWorkflow() -> String {
        String(localized: LocalizedStringResource("Open the workflow", locale: locale, comment: "Button on the Overview’s headline: opens a workflow"))
    }

    // MARK: Plan

    func planUsedUp() -> String {
        String(localized: LocalizedStringResource(
            "The plan is **used up**.", locale: locale,
            comment: "Headline of the Overview when the Xcode Cloud plan is spent. Put the words for “used up” between the double asterisks, which are not shown."
        ))
    }

    func planRunsOut(on date: Date) -> String {
        let day = day(date)
        return String(localized: LocalizedStringResource(
            "The plan will run out on **\(day)**.", locale: locale,
            comment: "Headline of the Overview when the plan runs out before the cycle ends at the current pace. The placeholder is a date such as “November 2”, put forward between the double asterisks, which are not shown."
        ))
    }

    func resetsOn(_ date: Date) -> String {
        let day = day(date)
        return String(localized: LocalizedStringResource("It resets on \(day).", locale: locale, comment: "Under the headline about a spent plan. The placeholder is a date."))
    }

    /// “3 days before the reset”
    func beforeReset(days: Int) -> String {
        guard days >= 1 else {
            return String(localized: LocalizedStringResource("Just before the reset", locale: locale, comment: "How long before the plan resets it runs out: the same day"))
        }
        return String(localized: LocalizedStringResource("\(days) days before the reset", locale: locale, comment: "How long before the plan resets it runs out. The placeholder is a number of days."))
    }

    func planPaceLine(daysBeforeReset: Int) -> String {
        let before = beforeReset(days: daysBeforeReset)
        return String(localized: LocalizedStringResource(
            "\(before), at this cycle’s pace. Estimate.", locale: locale,
            comment: "Under the headline about the plan running out. The placeholder is how long before the reset, such as “3 days before the reset”. The figure is an estimate."
        ))
    }

    func planNote(on date: Date, daysBeforeReset: Int) -> String {
        let day = day(date)
        let before = beforeReset(days: daysBeforeReset)
        return String(localized: LocalizedStringResource(
            "Runs out around \(day), \(before) (estimate).", locale: locale,
            comment: "Small note about the plan running out. The placeholders are a date and how long before the reset, such as “3 days before the reset”."
        ))
    }

    func planUsedUpNote(resetting date: Date) -> String {
        let day = day(date)
        return String(localized: LocalizedStringResource("Used up, resets on \(day) (estimate).", locale: locale, comment: "Small note about a spent plan. The placeholder is the reset date."))
    }

    // MARK: Stuck

    func stuck(build: String, elapsed: TimeInterval) -> String {
        let length = duration(elapsed)
        return String(localized: LocalizedStringResource(
            "\(plain(build)) has been running for **\(length)**.", locale: locale,
            comment: "Headline of the Overview when a build runs far longer than usual. The placeholders are the build, such as “Brioche #412”, and a duration put forward between the double asterisks, which are not shown."
        ))
    }

    func stuckNote(build: String, elapsed: TimeInterval) -> String {
        let length = duration(elapsed)
        return String(localized: LocalizedStringResource(
            "\(plain(build)) has been running for \(length).", locale: locale,
            comment: "Small note about a build that runs far longer than usual. The placeholders are the build and a duration."
        ))
    }

    func usualWorkflow(_ workflow: String, usual: TimeInterval) -> String {
        let length = duration(usual)
        return String(localized: LocalizedStringResource(
            "Usually, \(plain(workflow)) finishes in \(length).", locale: locale,
            comment: "Under a build that runs long. The placeholders are the workflow’s name and its usual duration."
        ))
    }

    func usualAction(_ action: String, usual: TimeInterval) -> String {
        let length = duration(usual)
        return String(localized: LocalizedStringResource(
            "Usually, \(plain(action)) takes \(length).", locale: locale,
            comment: "Under a build that runs long. The placeholders are the name of the action it is on and its usual duration."
        ))
    }

    // MARK: Slowdown

    func slowdown(app: String, since date: Date) -> String {
        let day = day(date)
        return String(localized: LocalizedStringResource(
            "\(plain(app)) is slowing down since **\(day)**.", locale: locale,
            comment: "Headline of the Overview when a workflow’s builds got longer. The placeholders are the app’s name and a date such as “October 7”, put forward between the double asterisks, which are not shown."
        ))
    }

    func slowdownNote(app: String, workflow: String, increase: Double, build: Int?) -> String {
        let percent = percent(increase)
        let from = build.map { "#\($0)" } ?? String(localized: LocalizedStringResource("a build", locale: locale, comment: "A build whose number is unknown, in “since a build”"))
        return String(localized: LocalizedStringResource(
            "\(plain(app)) · \(plain(workflow)) slowed down by \(percent) since \(from).", locale: locale,
            comment: "Small note: the app, the workflow, how much longer its builds take, and the build from which. Keep the middle dot."
        ))
    }

    func slowdownDetail(_ model: WorkflowSlowdownModel) -> String {
        let slowdown = model.slowdown
        let change: String
        if let action = slowdown.mainAction {
            let before = WorkflowSlowdownText.duration(action.before, locale: locale)
            let after = WorkflowSlowdownText.duration(action.after, locale: locale)
            change = String(localized: LocalizedStringResource(
                "\(plain(action.name)) went from \(before) to \(after).", locale: locale,
                comment: "Which action of a workflow got longer: its name, then its median before and after"
            ))
        } else {
            let before = WorkflowSlowdownText.duration(slowdown.medianBefore, locale: locale)
            let after = WorkflowSlowdownText.duration(slowdown.medianAfter, locale: locale)
            change = String(localized: LocalizedStringResource(
                "The median went from \(before) to \(after).", locale: locale,
                comment: "How much longer a workflow’s builds take: its median before and after"
            ))
        }
        guard let extra = model.extra else { return change }
        return change + " " + WorkflowSlowdownText.extraLine(extra, locale: locale)
    }

    func slowdownLine(_ model: WorkflowSlowdownModel, build: Int?) -> String {
        let slowdown = model.slowdown
        let from = build.map { "#\($0)" } ?? "?"
        let detail: String
        if let action = slowdown.mainAction {
            let before = WorkflowSlowdownText.duration(action.before, locale: locale)
            let after = WorkflowSlowdownText.duration(action.after, locale: locale)
            detail = String(localized: LocalizedStringResource(
                "\(plain(action.name)) went from \(before) to \(after) since \(from).", locale: locale,
                comment: "Under the headline about a slowdown: the action, its median before and after, and the build from which"
            ))
        } else {
            let before = WorkflowSlowdownText.duration(slowdown.medianBefore, locale: locale)
            let after = WorkflowSlowdownText.duration(slowdown.medianAfter, locale: locale)
            detail = String(localized: LocalizedStringResource(
                "The median went from \(before) to \(after) since \(from).", locale: locale,
                comment: "Under the headline about a slowdown: the workflow’s median before and after, and the build from which"
            ))
        }
        guard let extra = model.extra else { return detail }
        return detail + " " + WorkflowSlowdownText.extraLine(extra, locale: locale)
    }

    // MARK: Apple

    func appleIncident() -> String {
        String(localized: LocalizedStringResource(
            "Apple reports an **incident** on Xcode Cloud.", locale: locale,
            comment: "Headline of the Overview while Apple’s status page lists an incident on Xcode Cloud. Put the word for “incident” between the double asterisks, which are not shown."
        ))
    }

    func appleLine(since start: Date, now: Date, stoppedBuilds: Int) -> String {
        let moment = AppleStatusFormat.moment(start, now: now, locale: locale, timeZone: calendar.timeZone)
        let source = String(localized: LocalizedStringResource(
            "Since \(moment), according to Apple’s system status page.", locale: locale,
            comment: "Under the headline about an Apple incident. The placeholder is a time such as “2:10 PM”."
        ))
        guard stoppedBuilds > 0 else { return source }
        let stopped = String(localized: LocalizedStringResource(
            "\(stoppedBuilds) builds stopped since.", locale: locale, comment: "How many builds ended in error during an Apple incident. The placeholder is a number."
        ))
        return source + " " + stopped
    }

    func appleNote(since start: Date, now: Date) -> String {
        let moment = AppleStatusFormat.moment(start, now: now, locale: locale, timeZone: calendar.timeZone)
        return String(localized: LocalizedStringResource(
            "Apple reports an incident on Xcode Cloud since \(moment).", locale: locale,
            comment: "Small note while Apple’s status page lists an incident. The placeholder is a time such as “2:10 PM”."
        ))
    }

    func appleSource() -> String {
        String(localized: LocalizedStringResource("According to Apple’s system status page.", locale: locale, comment: "Says where a note about an incident comes from"))
    }

    // MARK: Running

    func runningEnds(build: String, at end: Date) -> String {
        let time = time(end)
        return String(localized: LocalizedStringResource(
            "\(plain(build)) finishes around **\(time)**.", locale: locale,
            comment: "Headline of the Overview while a build runs. The placeholders are the build, such as “Brioche #412”, and a time such as “2:36 PM”, put forward between the double asterisks, which are not shown."
        ))
    }

    func running(build: String) -> String {
        String(localized: LocalizedStringResource(
            "\(plain(build)) is **running**.", locale: locale,
            comment: "Headline of the Overview while a build runs and no end can be estimated. Put the word for “running” between the double asterisks, which are not shown."
        ))
    }

    func queued(build: String) -> String {
        String(localized: LocalizedStringResource(
            "\(plain(build)) is **waiting** in the queue.", locale: locale,
            comment: "Headline of the Overview while the only build is queued at Apple. Put the word for “waiting” between the double asterisks, which are not shown."
        ))
    }

    func runningLine(action: String?, remaining: BuildETA.Display?) -> String? {
        guard let remaining else { return action.map(runningAction) }
        let left = BuildETAFormat.approximate(remaining, locale: locale)
        guard let action else {
            return String(localized: LocalizedStringResource("\(left) left (estimate).", locale: locale, comment: "Under the headline about a running build: the time left, such as “~4 min”"))
        }
        let name = plain(action)
        return String(localized: LocalizedStringResource(
            "\(name) is running, \(left) left (estimate).", locale: locale,
            comment: "Under the headline about a running build: the action it is on, then the time left such as “~4 min”"
        ))
    }

    private func runningAction(_ action: String) -> String {
        let name = plain(action)
        return String(localized: LocalizedStringResource("\(name) is running.", locale: locale, comment: "Under the headline about a running build: the action it is on"))
    }

    func alsoQueued(build: String) -> String {
        String(localized: LocalizedStringResource("\(plain(build)) is waiting in the queue.", locale: locale, comment: "Under the headline about a running build: another build is queued"))
    }

    func alsoRunning(build: String) -> String {
        String(localized: LocalizedStringResource("\(plain(build)) is running too.", locale: locale, comment: "Under the headline about a running build: another build runs"))
    }

    func moreBuilds(_ count: Int) -> String {
        String(localized: LocalizedStringResource("\(count) more builds are running or queued.", locale: locale, comment: "Under the headline about a running build: how many other builds are running or queued. The placeholder is a number."))
    }

    // MARK: Passing

    func passing(since span: String?) -> String {
        guard let span else {
            return String(localized: LocalizedStringResource(
                "Everything is **passing**.", locale: locale,
                comment: "Headline of the Overview when every workflow’s latest build succeeded. Put the word for “passing” between the double asterisks, which are not shown."
            ))
        }
        return String(localized: LocalizedStringResource(
            "Everything is **passing** \(span).", locale: locale,
            comment: "Headline of the Overview when every workflow’s latest build succeeded. The placeholder is how long, such as “for 9 days” or “since yesterday”. Put the word for “passing” between the double asterisks, which are not shown."
        ))
    }

    func passingSpan(days: Int, isAtLeast: Bool) -> String? {
        if isAtLeast {
            return String(localized: LocalizedStringResource("for over \(days) days", locale: locale, comment: "How long everything has passed, with no failure in all the builds known. The placeholder is the number of days the builds cover."))
        }
        switch days {
        case ..<1: return nil
        case 1: return String(localized: LocalizedStringResource("since yesterday", locale: locale, comment: "How long a workflow has been failing: it started yesterday"))
        default: return forDays(days)
        }
    }

    /// “for 9 days”
    func forDays(_ days: Int) -> String {
        String(localized: LocalizedStringResource("for \(days) days", locale: locale, comment: "How long something has lasted. The placeholder is a number of days."))
    }

    func weekLine(builds: Int, successRate: Double?) -> String {
        guard builds > 0 else {
            return String(localized: LocalizedStringResource("No build this week.", locale: locale, comment: "Under the headline when everything passes but nothing ran in the last seven days"))
        }
        let count = String(localized: LocalizedStringResource("\(builds) builds this week", locale: locale, comment: "A number of builds in the last seven days"))
        guard let successRate else { return count + "." }
        let rate = percent(successRate)
        return String(localized: LocalizedStringResource("\(count), \(rate) succeeded.", locale: locale, comment: "Under the headline when everything passes. The placeholders are a count of builds such as “46 builds this week” and a percentage."))
    }

    // MARK: Reading

    func reading() -> String {
        String(localized: LocalizedStringResource(
            "Cumulus is **reading** your builds.", locale: locale,
            comment: "Headline of the Overview before any build was read. Put the word for “reading” between the double asterisks, which are not shown."
        ))
    }

    func readingLine(days: Int) -> String {
        String(localized: LocalizedStringResource("The last \(days) days are on their way; the mosaic fills in as they arrive.", locale: locale, comment: "Under the headline before any build was read. The placeholder is a number of days."))
    }

    // MARK: TestFlight

    func testFlightWaiting(app: String, build: String, days: Int) -> String {
        let span = forDays(days)
        return String(localized: LocalizedStringResource(
            "\(plain(app)) \(plain(build)) has been waiting for Apple’s beta review \(span).", locale: locale,
            comment: "Small note about a TestFlight build in the beta review queue. The placeholders are the app, the version and build number such as “1.4 (412)”, and how long, such as “for 2 days”."
        ))
    }

    func testFlightExpiry(app: String, build: String, days: Int) -> String {
        let when = String(localized: LocalizedStringResource("in \(days) days", locale: locale, comment: "When a TestFlight build stops working. The placeholder is a number of days."))
        return String(localized: LocalizedStringResource(
            "\(plain(app)) \(plain(build)): the latest build for external testers expires \(when).", locale: locale,
            comment: "Small note about a TestFlight build that stops working soon. The placeholders are the app, the version and build number such as “2.1 (87)”, and when, such as “in 5 days”."
        ))
    }

    // MARK: Flaky tests, Xcode

    func flakyTests(app: String, workflow: String, count: Int) -> String {
        let tests = String(localized: LocalizedStringResource("\(count) flaky tests", locale: locale, comment: "A number of tests that pass and fail without a code change"))
        return String(localized: LocalizedStringResource(
            "\(plain(app)) · \(plain(workflow)) has \(tests).", locale: locale,
            comment: "Small note about flaky tests. The placeholders are the app, the workflow and a count such as “2 flaky tests”. Keep the middle dot."
        ))
    }

    func flakyDetail(names: [String]) -> String {
        let shown = names.prefix(2).map(plain)
        let list = shown.formatted(.list(type: .and).locale(locale))
        let more = names.count - shown.count
        guard more > 0 else { return list + "." }
        let extra = String(localized: LocalizedStringResource("+\(more) more", locale: locale, comment: "After two test names: how many more there are"))
        return list + ", " + extra + "."
    }

    func xcodeOutdated(app: String, workflow: String, current: String, latest: String) -> String {
        String(localized: LocalizedStringResource(
            "\(plain(app)) · \(plain(workflow)) uses \(plain(current)); \(plain(latest)) is available.", locale: locale,
            comment: "Small note: a workflow stays on an older Xcode. The placeholders are the app, the workflow, its Xcode version and the newest one. Keep the middle dot."
        ))
    }

    func otherXcodeWorkflows(_ count: Int) -> String {
        String(localized: LocalizedStringResource("\(count) other workflows are on an older Xcode.", locale: locale, comment: "Under a note about an old Xcode: how many other workflows are too. The placeholder is a number."))
    }

    // MARK: Labels

    func label(_ kind: OverviewHeadline.Note.Kind) -> String {
        switch kind {
        case .broken: String(localized: LocalizedStringResource("Broken", locale: locale, comment: "Label above a small note on the Overview: a workflow fails. Short, shown in capitals."))
        case .plan: String(localized: LocalizedStringResource("Plan", locale: locale, comment: "Label above a small note on the Overview: the Xcode Cloud plan. Short, shown in capitals."))
        case .stuck: String(localized: LocalizedStringResource("Stuck", locale: locale, comment: "Label above a small note on the Overview: a build runs far too long. Short, shown in capitals."))
        case .slowdown: String(localized: LocalizedStringResource("Slowdown", locale: locale, comment: "Label above a small note on the Overview: a workflow got slower. Short, shown in capitals."))
        case .testFlight: String(localized: LocalizedStringResource("TestFlight", locale: locale, comment: "Label above a small note on the Overview. Short, shown in capitals."))
        case .flakyTests: String(localized: LocalizedStringResource("Flaky tests", locale: locale, comment: "Label above a small note on the Overview: tests that pass and fail without a code change. Short, shown in capitals."))
        case .xcode: String(localized: LocalizedStringResource("Xcode", locale: locale, comment: "Label above a small note on the Overview: an old Xcode version. Short, shown in capitals."))
        case .apple: String(localized: LocalizedStringResource("Apple", locale: locale, comment: "Label above a small note on the Overview: an incident at Apple. Short, shown in capitals."))
        }
    }
}
