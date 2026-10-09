import Foundation

nonisolated enum UsageFormat {
    static func minutes(_ minutes: Double) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = rounded >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(rounded * 60).formatted(.units(allowed: allowed, width: .abbreviated))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func timeLeft(_ interval: TimeInterval) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = interval >= 86_400 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(Int(interval)).formatted(.units(allowed: allowed, width: .abbreviated, maximumUnitCount: 2))
    }
}
