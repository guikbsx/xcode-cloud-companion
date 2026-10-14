import Foundation

/// The TestFlight card of an app: its latest builds, one line each.
nonisolated struct TestFlightCardModel: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        /// “1.4 (412)”.
        let label: String
        let testers: String?
        let status: TestFlightStatus
        /// The state in words, with how long the beta review has had the build when that is known.
        let statusText: String
        /// “Expires in 6 days”, under 14 days.
        let expiry: String?
        let spoken: String

        var isExpired: Bool { status == .expired }
    }

    static let visibleRows = 3
    /// A build is said to be expiring from this many days before.
    static let warningDays = 14

    let rows: [Row]

    static func make(builds: [TestFlightBuild], now: Date, locale: Locale = .autoupdatingCurrent) -> TestFlightCardModel {
        let newest = builds.sorted { ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast) }.prefix(visibleRows)
        return TestFlightCardModel(rows: newest.map { row(for: $0, now: now, locale: locale) })
    }

    private static func row(for build: TestFlightBuild, now: Date, locale: Locale) -> Row {
        let status = build.status(at: now)
        let statusText = TestFlightText.statusLine(of: build, now: now, locale: locale)
        let testers = TestFlightText.testers(build.testers(at: now))
        let expiry = build.daysLeft(at: now).flatMap { $0 <= warningDays ? TestFlightText.expiresIn(days: $0) : nil }
        return Row(
            id: build.id, label: build.label, testers: testers, status: status, statusText: statusText, expiry: expiry,
            spoken: UsageFormat.dotted([build.label, testers, statusText, expiry].compactMap(\.self), locale: locale)
        )
    }

    /// The rows of its skeleton: three lines of typical length.
    static let placeholder = TestFlightCardModel(rows: [
        Row(id: "1", label: "1.4 (412)", testers: "Internal and external testers", status: .available, statusText: "Available", expiry: nil, spoken: ""),
        Row(id: "2", label: "1.4 (409)", testers: "Internal and external testers", status: .available, statusText: "Available", expiry: "Expires in 6 days", spoken: ""),
        Row(id: "3", label: "1.3 (388)", testers: nil, status: .expired, statusText: "Expired on 2 Oct", expiry: nil, spoken: ""),
    ])
}

/// “From the commit to the testers”: the steps a build went through, with the times that are known and no others. Apple
/// dates the upload and the sending to the beta review; the end of the processing and the availability are states.
/// When Cumulus watched one of them change, it says when it saw it, as such.
nonisolated struct TestFlightTimeline: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case done, current, upcoming, failed, ended
    }

    struct Step: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let detail: String?
        let state: State
    }

    let steps: [Step]

    static func make(
        build: TestFlightBuild, observation: TestFlightObservation?, archiveFinished: Date?, now: Date,
        calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> TestFlightTimeline {
        func clock(_ date: Date) -> String { TestFlightText.clock(date, now: now, calendar: calendar, locale: locale) }
        func seen(_ date: Date?) -> String? { Self.seen(date, now: now, calendar: calendar, locale: locale) }
        var steps: [Step] = []
        steps.append(Step(
            id: "archive", name: String(localized: "Archive succeeded", comment: "First step of the TestFlight timeline"),
            detail: archiveFinished.map(clock), state: .done
        ))
        if let uploaded = build.uploadedDate {
            steps.append(Step(id: "upload", name: String(localized: "Uploaded", comment: "Step of the TestFlight timeline: the build reached App Store Connect"), detail: clock(uploaded), state: .done))
        }
        let processing = String(localized: "Processing done", comment: "Step of the TestFlight timeline")
        switch build.processing {
        case .valid:
            steps.append(Step(id: "processing", name: processing, detail: seen(observation?.processedSeenAt), state: .done))
        case .processing:
            steps.append(Step(id: "processing", name: processing, detail: String(localized: "in progress", comment: "Under a step of the TestFlight timeline that is under way"), state: .current))
        case .failed, .invalid:
            steps.append(Step(id: "processing", name: processing, detail: String(localized: "failed", comment: "Under a step of the TestFlight timeline that did not succeed"), state: .failed))
        case .unknown:
            break
        }
        if build.review != nil || build.reviewSubmittedDate != nil {
            steps.append(Step(
                id: "review", name: String(localized: "Beta review sent", comment: "Step of the TestFlight timeline"),
                detail: build.reviewSubmittedDate.map(clock), state: .done
            ))
        }
        if let final = availability(of: build, observation: observation, now: now, calendar: calendar, locale: locale) {
            steps.append(final)
        }
        return TestFlightTimeline(steps: steps)
    }

    /// When Cumulus noticed a step had happened: its own time, said as such.
    private static func seen(_ date: Date?, now: Date, calendar: Calendar, locale: Locale) -> String? {
        date.map {
            String(localized: "seen at \(TestFlightText.clock($0, now: now, calendar: calendar, locale: locale))", comment: "Under a step of the TestFlight timeline: the time Cumulus noticed the step had happened, not a time Apple gave")
        }
    }

    private static func availability(
        of build: TestFlightBuild, observation: TestFlightObservation?, now: Date, calendar: Calendar, locale: Locale
    ) -> Step? {
        let name = String(localized: "Available to testers", comment: "Last step of the TestFlight timeline")
        let waiting = String(localized: "waiting", comment: "Under a step of the TestFlight timeline that has not happened yet")
        func seen(_ date: Date?) -> String? { Self.seen(date, now: now, calendar: calendar, locale: locale) }
        switch build.status(at: now) {
        case .expired:
            return Step(id: "available", name: name, detail: TestFlightText.expired(on: build.expirationDate, locale: locale), state: .ended)
        case .rejected:
            return Step(id: "available", name: name, detail: String(localized: "rejected", comment: "Under a step of the TestFlight timeline that the beta review turned down"), state: .failed)
        case .waitingForReview, .inReview, .processing, .ready:
            return Step(id: "available", name: name, detail: waiting, state: .upcoming)
        case .processingFailed, .unknown:
            return nil
        case .available:
            // Seen in testing with the external testers, or else with the team's own.
            let date = build.externalState == .testing ? observation?.externalAvailableSeenAt : observation?.internalAvailableSeenAt
            return Step(id: "available", name: name, detail: seen(date), state: .done)
        }
    }
}
