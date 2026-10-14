import Foundation

/// The words of the incident notice: Cumulus's own, never Apple's text, and times in the Mac's zone.
nonisolated enum AppleStatusFormat {
    struct Banner: Equatable {
        var title: String
        var detail: String
    }

    /// The time alone when it is today, with the day when it is not.
    static func moment(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        var style: Date.FormatStyle = calendar.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated).hour().minute()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// `stoppedAt` is when the build ended; the notice says nothing of it when that is not known.
    static func banner(
        for event: AppleStatusEvent, stoppedAt: Date?, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
    ) -> Banner {
        let start = moment(event.start, now: now, locale: locale, timeZone: timeZone)
        let title: String
        if let end = event.end {
            let finish = moment(end, now: now, locale: locale, timeZone: timeZone)
            title = String(localized: LocalizedStringResource(
                "Apple reported an incident on Xcode Cloud, from \(start) to \(finish)", locale: locale,
                comment: "Title of the notice on a build that stopped during an incident Apple has since closed. Two times."
            ))
        } else {
            title = String(localized: LocalizedStringResource(
                "Apple reports an incident on Xcode Cloud since \(start)", locale: locale,
                comment: "Title of the notice on a build that stopped during an incident Apple has not closed. One time."
            ))
        }
        let source = String(localized: LocalizedStringResource(
            "According to Apple’s system status page.", locale: locale, comment: "Says where the notice about an incident comes from"
        ))
        guard let stoppedAt else { return Banner(title: title, detail: source) }
        let stopped = moment(stoppedAt, now: now, locale: locale, timeZone: timeZone)
        let stop = String(localized: LocalizedStringResource(
            "This build stopped at \(stopped).", locale: locale, comment: "Notice about an incident: when the build stopped. One time."
        ))
        return Banner(title: title, detail: "\(stop) \(source)")
    }

    static func menuLine(locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: LocalizedStringResource(
            "Xcode Cloud: incident in progress at Apple", locale: locale, comment: "Line of the menu while Apple reports an incident on Xcode Cloud"
        ))
    }

    /// The banner that says the incident is over. `erroredBuilds` is how many builds of the followed accounts ended in error during it.
    static func recoveryNotification(erroredBuilds: Int, locale: Locale = .autoupdatingCurrent) -> LocalNotification {
        let body = erroredBuilds > 0
            ? String(localized: LocalizedStringResource(
                "The incident reported by Apple is over. \(erroredBuilds) builds stopped during that time.", locale: locale,
                comment: "Banner when Apple closes an incident on Xcode Cloud; the number is how many builds ended in error during it"
            ))
            : String(localized: LocalizedStringResource(
                "The incident reported by Apple is over.", locale: locale, comment: "Banner when Apple closes an incident on Xcode Cloud, with no build to count"
            ))
        return LocalNotification(
            id: "apple-status-recovered",
            title: String(localized: LocalizedStringResource("Xcode Cloud is back", locale: locale, comment: "Title of the banner when an incident reported by Apple is over")),
            body: body, url: CumulusURL.builds, thread: "apple-status"
        )
    }
}
