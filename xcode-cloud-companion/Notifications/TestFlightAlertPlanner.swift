import Foundation

/// What was said of an app's TestFlight builds, by build: a banner speaks once for each.
nonisolated struct TestFlightAlertState: Codable, Sendable, Equatable {
    /// Builds known to be in testing with external testers, said or already so when the app was first read.
    var availableReported: Set<String> = []
    /// Builds whose coming expiry was said.
    var expiryReported: Set<String> = []
}

nonisolated struct TestFlightAlerts: Sendable, Equatable {
    var available: [LocalNotification] = []
    var expiring: [LocalNotification] = []
    var state = TestFlightAlertState()
}

/// Turns a read of an app's TestFlight builds into banners: one when a build reaches external testers, one when the
/// build they have is a week from expiring.
nonisolated enum TestFlightAlertPlanner {
    static let expiryLead: TimeInterval = 7 * 86400

    /// `isBaseline` is the first read of the app in this session: it says where things stand. A build then in testing is not
    /// news. A coming expiry is not recorded as said either, so that it still speaks at the next read.
    static func evaluate(
        app: TestFlightApp, builds: [TestFlightBuild], state: TestFlightAlertState, isBaseline: Bool, now: Date, locale: Locale = .autoupdatingCurrent
    ) -> TestFlightAlerts {
        var alerts = TestFlightAlerts()
        let ids = Set(builds.map(\.id))
        var next = TestFlightAlertState(
            availableReported: state.availableReported.intersection(ids), expiryReported: state.expiryReported.intersection(ids)
        )

        let available = builds.filter { $0.isAvailableToExternalTesters(at: now) }
        for build in available where !next.availableReported.contains(build.id) {
            next.availableReported.insert(build.id)
            guard !isBaseline else { continue }
            alerts.available.append(LocalNotification(
                id: "testflight-available-\(build.id)",
                title: TestFlightText.availableTitle(app: app.name, build: build.label),
                body: TestFlightText.availableBody(review: build.review),
                url: CumulusURL.app(productID: app.productID), thread: app.productID
            ))
        }

        // The build external testers are on is the newest one in testing with them: a newer one that is not there yet does not replace it.
        if !isBaseline, let latest = available.max(by: { ($0.uploadedDate ?? .distantPast) < ($1.uploadedDate ?? .distantPast) }),
           let expiration = latest.expirationDate, !next.expiryReported.contains(latest.id) {
            let left = expiration.timeIntervalSince(now)
            if left > 0, left <= expiryLead, let days = latest.daysLeft(at: now) {
                next.expiryReported.insert(latest.id)
                alerts.expiring.append(LocalNotification(
                    id: "testflight-expiry-\(latest.id)",
                    title: TestFlightText.expiringTitle(app: app.name, days: days),
                    body: TestFlightText.expiringBody(on: expiration, locale: locale),
                    url: CumulusURL.app(productID: app.productID), thread: app.productID
                ))
            }
        }
        alerts.state = next
        return alerts
    }
}
