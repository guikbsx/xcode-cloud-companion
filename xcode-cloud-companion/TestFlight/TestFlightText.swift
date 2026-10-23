import Foundation

/// The words of the TestFlight card, its timeline and its banners.
nonisolated enum TestFlightText {
    static func status(_ status: TestFlightStatus) -> String {
        switch status {
        case .processing: String(localized: "Processing", comment: "State of a TestFlight build that Apple is still processing")
        case .processingFailed: String(localized: "Processing failed", comment: "State of a TestFlight build whose processing failed")
        case .waitingForReview: String(localized: "Waiting for beta review", comment: "State of a TestFlight build sent to the beta review, which has not started")
        case .inReview: String(localized: "In beta review", comment: "State of a TestFlight build that the beta review is looking at")
        case .rejected: String(localized: "Rejected in beta review", comment: "State of a TestFlight build the beta review turned down")
        case .available: String(localized: "Available", comment: "State of a TestFlight build that testers can install")
        case .ready: String(localized: "Ready", comment: "State of a TestFlight build that is processed but in no group of testers yet")
        case .expired: String(localized: "Expired", comment: "State of a TestFlight build that stopped working after 90 days")
        case .unknown: String(localized: "Status unknown", comment: "State of a TestFlight build that Cumulus cannot tell")
        }
    }

    static func testers(_ testers: TestFlightTesters) -> String? {
        switch (testers.hasInternal, testers.hasExternal) {
        case (true, true): String(localized: "Internal and external testers", comment: "Who a TestFlight build is for")
        case (true, false): String(localized: "Internal testers", comment: "Who a TestFlight build is for")
        case (false, true): String(localized: "External testers", comment: "Who a TestFlight build is for")
        case (false, false): nil
        }
    }

    static func expiresIn(days: Int) -> String {
        String(localized: "Expires in \(days) days", comment: "Beside a TestFlight build that stops working soon; the placeholder is a number of days")
    }

    static func expired(on date: Date?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else { return status(.expired) }
        return String(localized: "Expired on \(UsageFormat.day(date, locale: locale))", comment: "Beside a TestFlight build that stopped working; the placeholder is a date")
    }

    static func since(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "since \(UsageFormat.age(since: date, now: now, locale: locale))", comment: "After a state: how long a TestFlight build has been in it, such as “since 3h”")
    }

    /// The state, and how long a build has waited for its beta review.
    /// `expiredSeenAt` is when Cumulus saw the build expire; it stands in for an expiry date that has not come yet, which is what a
    /// build expired by hand may still carry.
    static func statusLine(of build: TestFlightBuild, now: Date, expiredSeenAt: Date? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        let status = build.status(at: now)
        switch status {
        case .expired:
            let date = build.expirationDate.flatMap { $0 <= now ? $0 : nil } ?? expiredSeenAt
            return expired(on: date, locale: locale)
        case .waitingForReview, .inReview:
            return UsageFormat.dotted([Self.status(status), build.reviewSubmittedDate.map { since($0, now: now, locale: locale) }].compactMap(\.self), locale: locale)
        default:
            return Self.status(status)
        }
    }

    // MARK: Banners

    static func availableTitle(app: String, build: String) -> String {
        String(localized: "\(app) \(build) is available to external testers", comment: "Banner title: the first placeholder is an app's name, the second a version and build number such as “1.4 (412)”")
    }

    static func availableBody(review: TestFlightReviewState?) -> String {
        review == .approved
            ? String(localized: "The beta review passed.", comment: "Banner body: a TestFlight build became available after its beta review")
            : String(localized: "Testers can install it from TestFlight.", comment: "Banner body: a TestFlight build became available to external testers")
    }

    static func expiringTitle(app: String, days: Int) -> String {
        String(localized: "\(app): the latest TestFlight build expires in \(days) days", comment: "Banner title: the first placeholder is an app's name, the second a number of days")
    }

    static func expiringBody(on date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "After \(UsageFormat.day(date, locale: locale)), external testers will have no build to install.", comment: "Banner body: the placeholder is a date such as “19 Oct”")
    }

    /// A time of the timeline: just the clock for today, the day too for an earlier one.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        calendar.isDate(date, inSameDayAs: now) ? UsageFormat.time(date, locale: locale) : UsageFormat.moment(date, locale: locale)
    }
}
