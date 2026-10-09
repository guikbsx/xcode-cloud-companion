import Foundation

/// Every figure of the interface, formatted for a locale: the user's by default, any other in tests.
nonisolated enum UsageFormat {
    static func minutes(_ minutes: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = rounded >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(rounded * 60).formatted(.units(allowed: allowed, width: .abbreviated).locale(locale))
    }

    /// Short form for tight columns: “8h 19m”, “37m”.
    static func compactMinutes(_ minutes: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = rounded >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(rounded * 60).formatted(.units(allowed: allowed, width: .narrow).locale(locale))
    }

    /// Age in the largest whole unit, never rounded up: “now”, “4m”, “1h”, “1d”.
    static func age(since date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= 60 else {
            return String(localized: LocalizedStringResource("now", locale: locale, comment: "Age of a build created less than a minute ago. Very short."))
        }
        let (unit, length): (Duration.UnitsFormatStyle.Unit, Double) = seconds >= 86_400 ? (.days, 86_400) : seconds >= 3_600 ? (.hours, 3_600) : (.minutes, 60)
        let whole = Int(seconds / length) * Int(length)
        return Duration.seconds(whole).formatted(.units(allowed: [unit], width: .narrow, maximumUnitCount: 1).locale(locale))
    }

    static func percent(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func day(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    static func moment(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }

    static func relative(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func timeLeft(_ interval: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = interval >= 86_400 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(Int(interval)).formatted(.units(allowed: allowed, width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    /// Parts of a line separated by “ · ”, the separator coming from the catalog so a language can change it.
    static func dotted(_ parts: [String], locale: Locale = .autoupdatingCurrent) -> String {
        guard var line = parts.first else { return "" }
        for part in parts.dropFirst() {
            line = String(localized: LocalizedStringResource(
                "\(line) · \(part)", locale: locale, comment: "Joins two parts of a line, such as a build's state and its duration. Keep the middle dot."
            ))
        }
        return line
    }
}
