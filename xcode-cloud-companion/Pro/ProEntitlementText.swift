import Foundation

/// How a state of Cumulus Pro is said, in the purchase sheet and in Settings.
nonisolated enum ProEntitlementText {
    static func day(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(locale))
    }

    static func title(_ entitlement: ProEntitlement, locale: Locale = .autoupdatingCurrent) -> String {
        switch entitlement {
        case .free: String(localized: "Free version")
        case .trial(let ends, _): String(localized: "Free trial, until \(day(ends, locale: locale))")
        case .subscribed: String(localized: "Cumulus Pro, yearly")
        case .lifetime: String(localized: "Cumulus Pro, lifetime")
        case .expired(let on): String(localized: "Cumulus Pro ended on \(day(on, locale: locale))")
        }
    }

    static func detail(_ entitlement: ProEntitlement, locale: Locale = .autoupdatingCurrent) -> String {
        switch entitlement {
        case .free:
            String(localized: "One account, its usage and its builds. Pro adds the alerts, the diagnostics and the agents.")
        case .trial(_, let willRenew):
            willRenew
                ? String(localized: "The yearly subscription starts then. Nothing is charged before that date.")
                : String(localized: "Renewal is off: Cumulus Pro stops on that date, and nothing is charged.")
        case .subscribed(let until, let willRenew):
            willRenew
                ? String(localized: "Renews on \(day(until, locale: locale)).")
                : String(localized: "Renewal is off: Cumulus Pro stops on \(day(until, locale: locale)).")
        case .lifetime(let since):
            String(localized: "Bought on \(day(since, locale: locale)). Nothing to renew.")
        case .expired:
            String(localized: "Nothing is erased: your accounts, your builds and your settings are intact. The Pro functions are paused.")
        }
    }
}
