import Foundation

nonisolated enum UsageAlert: String, Codable, Sendable, CaseIterable {
    case threshold75
    case threshold90
    /// The pace of the cycle says the plan runs out before it resets.
    case pace

    var threshold: Double? {
        switch self {
        case .threshold75: 0.75
        case .threshold90: 0.9
        case .pace: nil
        }
    }
}

/// Which plan alerts are wanted, as chosen in Settings.
nonisolated struct UsageAlertRules: Sendable, Equatable {
    var threshold75 = true
    var threshold90 = true
    var pace = true

    func includes(_ alert: UsageAlert) -> Bool {
        switch alert {
        case .threshold75: threshold75
        case .threshold90: threshold90
        case .pace: pace
        }
    }
}

/// What was already said in a cycle, so each alert is given once; a new cycle starts over.
nonisolated struct UsageAlertState: Codable, Sendable, Equatable {
    var cycleStart: Date?
    var reported: Set<UsageAlert> = []
}

nonisolated enum UsageAlertPlanner {
    /// `accountID` tells two accounts' alerts apart, and brings the click to the right Overview.
    static func alerts(for summary: UsageSummary, rules: UsageAlertRules, state: inout UsageAlertState, accountID: String? = nil) -> [LocalNotification] {
        // While builds are still being measured the figure climbs by itself: a threshold crossed then means nothing.
        guard !summary.measurement.isMeasuring else { return [] }
        if state.cycleStart != summary.cycle.start {
            state = UsageAlertState(cycleStart: summary.cycle.start)
        }
        var notifications: [LocalNotification] = []

        // Only the highest threshold crossed speaks: at 92 %, "75 % used" would be noise.
        let crossed = [UsageAlert.threshold90, .threshold75].filter { alert in
            alert.threshold.map { summary.fractionUsed >= $0 } ?? false
        }
        if let highest = crossed.first(where: rules.includes), let threshold = highest.threshold {
            if !state.reported.contains(highest) {
                notifications.append(notification(
                    id: highest,
                    title: String(localized: "\(UsageFormat.percent(threshold)) of your Xcode Cloud plan used", comment: "Notification title: a percentage such as 75%."),
                    lines: [usedLine(summary), resetLine(summary)], summary: summary, accountID: accountID
                ))
            }
            // The thresholds below the one that spoke are settled with it.
            state.reported.formUnion(crossed.drop { $0 != highest })
        }

        if rules.pace, !state.reported.contains(.pace), summary.usedMinutes < summary.quotaMinutes, let exhaustion = summary.exhaustionDate {
            state.reported.insert(.pace)
            notifications.append(notification(
                id: .pace,
                title: String(localized: "Your Xcode Cloud plan may run out before it resets"),
                lines: [String(localized: "Runs out around \(UsageFormat.day(exhaustion)) at this pace"), resetLine(summary)], summary: summary,
                accountID: accountID
            ))
        }
        return notifications
    }

    /// Estimated minutes, or an export too old to cover the cycle: the figure is not Apple's.
    static func isEstimate(_ summary: UsageSummary) -> Bool {
        summary.estimatedMinutes > 0 || summary.isImportStale
    }

    // MARK: - Private

    private static func notification(id: UsageAlert, title: String, lines: [String], summary: UsageSummary, accountID: String?) -> LocalNotification {
        var body = UsageFormat.dotted(lines)
        if isEstimate(summary) {
            body += "\n" + String(localized: "Estimated from your builds: import a usage export for Apple’s exact figure.")
        }
        let suffix = accountID.map { "-\($0)" } ?? ""
        return LocalNotification(id: "usage-\(id.rawValue)\(suffix)", title: title, body: body, url: CumulusURL.overview(accountID: accountID), thread: "usage")
    }

    private static func usedLine(_ summary: UsageSummary) -> String {
        let used = (isEstimate(summary) ? "~" : "") + UsageFormat.minutes(summary.usedMinutes)
        return String(localized: "\(used) of \(UsageFormat.minutes(summary.quotaMinutes))")
    }

    private static func resetLine(_ summary: UsageSummary) -> String {
        String(localized: "Resets \(UsageFormat.day(summary.resetDate))")
    }
}
