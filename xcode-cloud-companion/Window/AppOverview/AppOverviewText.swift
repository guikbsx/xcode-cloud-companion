import Foundation

/// The words of an app's overview: each figure as the table writes it, and each row as VoiceOver reads it.
nonisolated enum AppOverviewText {
    /// “58 min”, “~17 min” for an estimate, “41 min + ~6 min” when Apple billed part of it.
    static func minutes(billed: Double, estimated: Double, locale: Locale = .autoupdatingCurrent) -> String {
        if estimated > 0, billed > 0 {
            return "\(UsageFormat.minutes(billed, locale: locale)) + ~\(UsageFormat.minutes(estimated, locale: locale))"
        }
        return (estimated > 0 ? "~" : "") + UsageFormat.minutes(billed + estimated, locale: locale)
    }

    static func minutes(_ minutes: Double, isEstimated: Bool, locale: Locale = .autoupdatingCurrent) -> String {
        (isEstimated ? "~" : "") + UsageFormat.minutes(minutes, locale: locale)
    }

    static func rate(_ fraction: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        fraction.map { UsageFormat.percent($0, locale: locale) } ?? "—"
    }

    static func duration(_ seconds: TimeInterval?, locale: Locale = .autoupdatingCurrent) -> String {
        seconds.map { UsageFormat.minutes($0 / 60, locale: locale) } ?? "—"
    }

    /// “Stable”, “+21 %”, or nothing while there are too few builds to compare.
    static func drift(_ drift: WorkflowTrends.Drift?, locale: Locale = .autoupdatingCurrent) -> String? {
        switch drift {
        case nil: nil
        case .stable: String(localized: "Stable", comment: "The newest builds of a workflow do not differ from the ones before")
        case .change(let fraction): fraction.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()).locale(locale))
        }
    }

    /// The branch, the tag or the pull request a build came from.
    static func reference(of run: CIBuildRun) -> String? {
        if let number = run.pullRequestNumber { return "#\(number)" }
        return run.sourceBranchOrTag?.nilIfBlank
    }

    /// Under a workflow's last build: “main · 1h”.
    static func lastBuildDetail(_ run: CIBuildRun, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        UsageFormat.dotted([reference(of: run), run.createdDate.map { UsageFormat.age(since: $0, now: now, locale: locale) }].compactMap(\.self), locale: locale)
    }

    /// What starts the workflow next, on two lines: when or on what, then what it costs or where.
    static func next(_ next: AppOverviewModel.Next?, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> (title: String, detail: String?) {
        switch next {
        case nil:
            return ("—", nil)
        case .scheduled(let date, let minutes):
            return (OverviewView.whenText(date, now: now, calendar: calendar, locale: locale), minutes.map { "~" + UsageFormat.minutes($0, locale: locale) })
        case .onChange(let trigger, let source):
            let title = switch trigger {
            case .branch: String(localized: "on push", comment: "What starts a workflow: a change pushed to a branch. Two words, in a table cell.")
            case .tag: String(localized: "on tag", comment: "What starts a workflow: a new tag. Two words, in a table cell.")
            case .pullRequest: String(localized: "on pull request", comment: "What starts a workflow: a change to a pull request. In a table cell.")
            }
            return (title, source)
        }
    }

    /// Under a workflow's name: its Xcode, and that it is paused.
    static func workflowDetail(_ row: AppOverviewModel.WorkflowRow, locale: Locale = .autoupdatingCurrent) -> String {
        let paused = row.isPaused ? String(localized: "paused", comment: "Beside a workflow of the sidebar that Apple says is paused. Lowercase, very short.") : nil
        return UsageFormat.dotted([row.xcodeVersion, paused].compactMap(\.self), locale: locale)
    }

    /// A row in one sentence, for VoiceOver: “Public archive, last build Failed, #395, main; success rate 58 %; …”.
    static func spoken(_ row: AppOverviewModel.WorkflowRow, showsMinutes: Bool, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [row.name]
        if row.isPaused { parts.append(String(localized: "paused", comment: "Beside a workflow of the sidebar that Apple says is paused. Lowercase, very short.")) }
        if let run = row.lastRun, let status = row.lastStatus {
            let build = [status.label, run.number.map { "#\($0)" }, reference(of: run)].compactMap(\.self).joined(separator: ", ")
            parts.append(String(localized: "last build \(build)", comment: "VoiceOver, a workflow's row: its last build's state, number and branch"))
        } else {
            parts.append(String(localized: "no build yet", comment: "VoiceOver and table cell: the workflow has never built in what the app knows"))
        }
        if let rate = row.successRate {
            parts.append(String(localized: "success rate \(UsageFormat.percent(rate, locale: locale))", comment: "VoiceOver, a workflow's row"))
        }
        if let seconds = row.medianDuration {
            parts.append(String(localized: "median duration \(UsageFormat.minutes(seconds / 60, locale: locale))", comment: "VoiceOver, a workflow's row"))
        }
        if showsMinutes, let cycle = row.cycleMinutes {
            parts.append(String(localized: "\(minutes(cycle, isEstimated: row.isEstimated, locale: locale)) this cycle", comment: "VoiceOver, a workflow's row: its minutes in the cycle"))
        }
        let coming = next(row.next, now: now, calendar: calendar, locale: locale)
        if row.next != nil {
            parts.append(String(localized: "next: \([coming.title, coming.detail].compactMap(\.self).joined(separator: ", "))", comment: "VoiceOver, a workflow's row: when it next starts, or what starts it"))
        }
        return parts.joined(separator: "; ")
    }
}
