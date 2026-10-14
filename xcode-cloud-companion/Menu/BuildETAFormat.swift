import Foundation

/// The words of a build's estimated end: the menu bar's few characters, what VoiceOver says, the line of the menu and of the sheet.
nonisolated enum BuildETAFormat {
    /// “~4 min”, or “< 1 min” under a minute, which is not a guess at the second.
    static func approximate(_ display: BuildETA.Display, locale: Locale = .autoupdatingCurrent) -> String {
        switch display {
        case .underAMinute:
            String(localized: LocalizedStringResource("< 1 min", locale: locale, comment: "Estimated time left of a running build, when under a minute. Very short: it goes in the menu bar."))
        case .minutes(let minutes):
            "~" + UsageFormat.minutes(Double(minutes), locale: locale)
        }
    }

    /// The menu bar item's text: the time left, preceded by the number of builds when several run; the number alone when
    /// none has an estimate; nil when nothing is to be said, then the bar is what it was.
    static func barText(runningCount: Int, display: BuildETA.Display?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard runningCount > 0 else { return nil }
        let count = runningCount > 1 ? runningCount.formatted(.number.locale(locale)) : nil
        return switch (count, display) {
        case let (count?, display?): UsageFormat.dotted([count, approximate(display, locale: locale)], locale: locale)
        case let (count?, nil): count
        case let (nil, display?): approximate(display, locale: locale)
        case (nil, nil): nil
        }
    }

    /// For VoiceOver: “estimated end in 4 minutes”.
    static func spoken(_ display: BuildETA.Display, locale: Locale = .autoupdatingCurrent) -> String {
        switch display {
        case .underAMinute:
            String(localized: LocalizedStringResource("estimated end in less than a minute", locale: locale, comment: "Said by VoiceOver for a running build that ends in under a minute"))
        case .minutes(let minutes):
            String(localized: LocalizedStringResource(
                "estimated end in \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale)))",
                locale: locale, comment: "Said by VoiceOver for a running build; the argument is a duration such as “4 minutes”"
            ))
        }
    }

    /// “Estimated end around 2:36 PM (~4 min)”.
    static func endLine(end: Date, display: BuildETA.Display, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: LocalizedStringResource(
            "Estimated end around \(UsageFormat.time(end, locale: locale)) (\(approximate(display, locale: locale)))",
            locale: locale, comment: "Line of a running build: when it should end, then how long from now. The second argument is such as “~4 min”."
        ))
    }
}

/// The setting that puts the time left in the menu bar; a preference of the app, not of an account.
nonisolated enum BuildETAFeature {
    static let settingKey = "menuBar.showsTimeLeft"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }
}
