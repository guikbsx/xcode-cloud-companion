import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

/// 19 November 2026, 22:00 UTC: a little over an hour after the newest build of the macOS fixture was uploaded.
private let now = Date(timeIntervalSince1970: 1_795_125_600)

private func iso(_ string: String) -> Date {
    (try? Date.ISO8601FormatStyle().parse(string)) ?? .distantPast
}

private func page(_ fixture: String) throws -> [TestFlightBuild] {
    let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<TestFlightBuildAttributes>.self, from: Fixture.data(fixture))
    return document.testFlightBuilds
}

private func build(
    _ id: String, uploaded: Date = now.addingTimeInterval(-3600), expires: Date? = nil, number: String? = nil, version: String? = "1.4",
    processing: TestFlightProcessing = .valid, internalState: TestFlightBetaState = .testing, external: TestFlightBetaState = .readyForSubmission,
    review: TestFlightReviewState? = nil, submitted: Date? = nil, groups: [TestFlightGroup] = [], expired: Bool = false
) -> TestFlightBuild {
    TestFlightBuild(
        id: id, buildNumber: number ?? id, marketingVersion: version, platform: "IOS", uploadedDate: uploaded,
        expirationDate: expires ?? uploaded.addingTimeInterval(90 * 86400), isMarkedExpired: expired, processing: processing,
        internalState: internalState, externalState: external, review: review, reviewSubmittedDate: submitted, groups: groups
    )
}

private let externalGroup = TestFlightGroup(name: "External testers", isInternal: false)
private let internalGroup = TestFlightGroup(name: "Internal", isInternal: true)

private let app = TestFlightApp(productID: "p1", appID: "app-1", name: "Brioche", newestShippedFinish: nil)

// MARK: - Decoding

struct TestFlightDecodingTests {
    @Test func aMacBuildComesWithItsReviewItsVersionAndItsGroups() throws {
        let builds = try page("testFlightBuilds-macos-review-and-external-group")

        #expect(builds.map(\.buildNumber) == ["7", "6", "5"], "newest upload first")
        let newest = try #require(builds.first)
        #expect(newest.marketingVersion == "1.0" && newest.platform == "MAC_OS" && newest.label == "1.0 (7)")
        #expect(newest.uploadedDate == iso("2026-11-19T20:38:53Z"), "the offset Apple writes is honoured")
        #expect(newest.expirationDate == iso("2027-02-17T20:38:53Z"))
        #expect(newest.processing == .valid && newest.internalState == .testing && newest.externalState == .testing)
        #expect(newest.review == .approved && newest.reviewSubmittedDate == iso("2026-11-19T20:41:24Z"))
        #expect(newest.groups.map(\.name) == ["Internal", "External testers"] && newest.groups.map(\.isInternal) == [true, false])
        #expect(newest.groups.map(\.id) == ["a11ce009-0000-4000-8000-000000001009", "a11ce00a-0000-4000-8000-00000000100a"], "the identifiers of the groups come with the build")
        #expect(newest.isAvailableToExternalTesters(at: now))

        let third = try #require(builds.last)
        #expect(third.review == nil && third.reviewSubmittedDate == nil && third.groups.isEmpty, "a build never sent to the review has none")
        #expect(third.internalState == .ready && third.externalState == .readyForSubmission)
    }

    @Test func anIosBuildWithOnlyInternalGroups() throws {
        let builds = try page("testFlightBuilds-ios-internal-groups")

        #expect(builds.count == 3 && builds.allSatisfy { $0.marketingVersion == "2.4.0" && $0.platform == "IOS" })
        #expect(builds.allSatisfy { $0.review == nil && $0.externalState == .readyForSubmission })
        #expect(builds.map(\.label) == ["2.4.0 (396)", "2.4.0 (395)", "2.4.0 (394)"])
        #expect(builds[0].groups.map(\.name) == ["Internal", "Internal QA"] && builds[1].groups.map(\.name) == ["Internal"])
        #expect(builds.flatMap(\.groups).allSatisfy { $0.isInternal })
        #expect(!builds[0].isAvailableToExternalTesters(at: now))
    }

    @Test func anExpiredBuildKeepsItsOwnState() throws {
        let builds = try page("testFlightBuilds-expired-and-review")

        #expect(builds.count == 6)
        let expired = try #require(builds.first { $0.buildNumber == "392" })
        #expect(expired.isMarkedExpired && expired.internalState == .expired && expired.externalState == .expired)
        #expect(expired.status(at: now) == .expired && expired.daysLeft(at: now) == nil)
        let lifetime = (expired.expirationDate ?? .distantPast).timeIntervalSince(expired.uploadedDate ?? .distantFuture)
        #expect(lifetime == 1382, "expired by hand 23 minutes after the upload")
        let reviewed = try #require(builds.first { $0.buildNumber == "393" })
        #expect(reviewed.groups.map(\.name) == ["Internal", "Internal QA", "External prod"] && reviewed.groups.map(\.isInternal) == [true, true, false])
        #expect(reviewed.review == .approved)
        #expect(reviewed.status(at: now) == .available)
    }

    @Test func aValueOfAppleThatTheAppDoesNotKnowReadsAsUnknownWithoutAnError() throws {
        let json = #"""
        {"data": [{"type": "builds", "id": "b1",
          "attributes": {"version": "9", "processingState": "SOMETHING_NEW"},
          "relationships": {
            "buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "b1"}},
            "betaAppReviewSubmission": {"data": {"type": "betaAppReviewSubmissions", "id": "b1"}},
            "betaGroups": {"data": [{"type": "betaGroups", "id": "g1"}, {"type": "betaGroups", "id": "gone"}]}}}],
         "included": [
          {"type": "buildBetaDetails", "id": "b1", "attributes": {"internalBuildState": "SOMETHING_ELSE", "externalBuildState": "FUTURE_STATE"}},
          {"type": "betaAppReviewSubmissions", "id": "b1", "attributes": {"betaReviewState": "SOMETHING"}},
          {"type": "betaGroups", "id": "g1", "attributes": {"name": "Friends"}}]}
        """#

        let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<TestFlightBuildAttributes>.self, from: Data(json.utf8))
        let build = try #require(document.testFlightBuilds.first)

        #expect(build.processing == .unknown && build.internalState == .unknown && build.externalState == .unknown && build.review == .unknown)
        #expect(build.groups == [TestFlightGroup(name: "Friends", isInternal: false, id: "g1")], "a group Apple did not include is left out")
        #expect(build.status(at: now) == .unknown)
        #expect(build.uploadedDate == nil && build.expirationDate == nil && build.daysLeft(at: now) == nil)
    }

    @Test func theStatesSeenNowhereYetAreReadFromAppleDocumentedValues() throws {
        func status(processing: String, internal internalState: String, external: String, review: String? = nil) throws -> TestFlightStatus {
            let reviewResource = review.map { #"{"type": "betaAppReviewSubmissions", "id": "b1", "attributes": {"betaReviewState": "\#($0)", "submittedDate": "2026-11-19T20:41:24-07:00"}},"# } ?? ""
            let reviewRelation = review == nil ? "" : #","betaAppReviewSubmission": {"data": {"type": "betaAppReviewSubmissions", "id": "b1"}}"#
            let json = """
            {"data": [{"type": "builds", "id": "b1", "attributes": {"version": "9", "processingState": "\(processing)", "uploadedDate": "2026-11-19T20:00:00Z", "expirationDate": "2027-02-01T00:00:00Z", "expired": false},
              "relationships": {"buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "b1"}}\(reviewRelation)}}],
             "included": [\(reviewResource){"type": "buildBetaDetails", "id": "b1", "attributes": {"internalBuildState": "\(internalState)", "externalBuildState": "\(external)"}}]}
            """
            let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<TestFlightBuildAttributes>.self, from: Data(json.utf8))
            return try #require(document.testFlightBuilds.first).status(at: now)
        }

        #expect(try status(processing: "PROCESSING", internal: "PROCESSING", external: "PROCESSING") == .processing)
        #expect(try status(processing: "FAILED", internal: "PROCESSING", external: "PROCESSING") == .processingFailed)
        #expect(try status(processing: "INVALID", internal: "PROCESSING", external: "PROCESSING") == .processingFailed)
        #expect(try status(processing: "VALID", internal: "IN_BETA_TESTING", external: "WAITING_FOR_BETA_REVIEW", review: "WAITING_FOR_REVIEW") == .waitingForReview)
        #expect(try status(processing: "VALID", internal: "IN_BETA_TESTING", external: "IN_BETA_REVIEW", review: "IN_REVIEW") == .inReview)
        #expect(try status(processing: "VALID", internal: "IN_BETA_TESTING", external: "BETA_REJECTED", review: "REJECTED") == .rejected)
        #expect(try status(processing: "VALID", internal: "IN_BETA_TESTING", external: "IN_BETA_TESTING", review: "APPROVED") == .available)
        #expect(try status(processing: "VALID", internal: "READY_FOR_BETA_TESTING", external: "READY_FOR_BETA_SUBMISSION") == .ready)
        #expect(try status(processing: "VALID", internal: "EXPIRED", external: "EXPIRED") == .expired)
    }
}

// MARK: - The request

struct TestFlightRequestTests {
    @Test func oneRequestPerAppAsksForTheFivePieces() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("testFlightBuilds-macos-review-and-external-group")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let builds = try await client.testFlightBuilds(appID: "app-9")

        #expect(builds.count == 3)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET" || request.httpMethod == nil)
        #expect(request.url?.path() == "/v1/builds")
        #expect(request.queryValue("filter[app]") == "app-9" && request.queryValue("sort") == "-uploadedDate" && request.queryValue("limit") == "5")
        #expect(request.queryValue("include") == "buildBetaDetail,preReleaseVersion,betaAppReviewSubmission,betaGroups")
        let fields = try #require(request.queryValue("fields[builds]")).split(separator: ",").map(String.init)
        for relation in ["buildBetaDetail", "preReleaseVersion", "betaAppReviewSubmission", "betaGroups", "expirationDate", "expired", "uploadedDate", "processingState", "version"] {
            #expect(fields.contains(relation), "\(relation) has to be named for Apple to answer with it")
        }
        #expect(request.queryValue("fields[betaGroups]") == "name,isInternalGroup")
    }

    @Test func aForbiddenAnswerIsNotReadAsAnEmptyApp() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: 403, body: (try? Fixture.data("errorResponse")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect(throws: AppStoreConnectError.self) { _ = try await client.testFlightBuilds(appID: "app-9") }
    }
}

// MARK: - What the card says

struct TestFlightPresentationTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    @Test func theCardKeepsTheThreeNewestBuildsAndSaysTheWordOfEachState() {
        let builds = [
            build("412", uploaded: now.addingTimeInterval(-3 * 3600), internalState: .testing, external: .waitingForReview, review: .waiting, submitted: now.addingTimeInterval(-3 * 3600), groups: [externalGroup]),
            build("409", uploaded: now.addingTimeInterval(-20 * 86400), expires: now.addingTimeInterval(6 * 86400 - 60), external: .testing, review: .approved, groups: [internalGroup, externalGroup]),
            build("388", uploaded: now.addingTimeInterval(-91 * 86400), expires: iso("2026-10-02T10:00:00Z"), internalState: .expired, external: .expired, expired: true),
            build("380", uploaded: now.addingTimeInterval(-95 * 86400)),
        ]

        let card = TestFlightCardModel.make(builds: builds, now: now, locale: locale)

        #expect(card.rows.map(\.label) == ["1.4 (412)", "1.4 (409)", "1.4 (388)"])
        #expect(card.rows.map(\.status) == [.waitingForReview, .available, .expired])
        #expect(card.rows[0].statusText == "Waiting for beta review · since 3h")
        #expect(card.rows[0].testers == "Internal and external testers" || card.rows[0].testers == "External testers")
        #expect(card.rows[1].testers == "Internal and external testers" && card.rows[1].statusText == "Available")
        #expect(card.rows[1].expiry == "Expires in 6 days")
        #expect(card.rows[2].statusText == "Expired on Oct 2" && card.rows[2].isExpired && card.rows[2].expiry == nil)
        #expect(card.rows[0].spoken.contains("Waiting for beta review") && card.rows[1].spoken.contains("Expires in 6 days"))
    }

    @Test func aWarningAppearsUnderFourteenDaysAndNotBefore() {
        let early = build("1", expires: now.addingTimeInterval(14 * 86400))
        let late = build("2", expires: now.addingTimeInterval(14 * 86400 + 3600))

        #expect(early.daysLeft(at: now) == 14 && late.daysLeft(at: now) == 15)
        let card = TestFlightCardModel.make(builds: [early, late], now: now, locale: locale)
        #expect(card.rows.contains { $0.id == "1" && $0.expiry == "Expires in 14 days" })
        #expect(card.rows.contains { $0.id == "2" && $0.expiry == nil })
    }

    @Test func aBuildWithoutGroupsIsStillForItsInternalTesters() {
        let alone = build("5", internalState: .testing)
        let waiting = build("6", internalState: .ready, external: .readyForSubmission)

        #expect(alone.testers(at: now) == TestFlightTesters(hasInternal: true, hasExternal: false))
        #expect(waiting.testers(at: now).isEmpty && TestFlightText.testers(waiting.testers(at: now)) == nil)
        #expect(waiting.status(at: now) == .ready)
    }

    @Test func theTimelineKeepsTheTimesApplesAndSaysTheOthersForWhatTheyAre() {
        let upload = iso("2026-11-19T14:02:00Z")
        let sent = iso("2026-11-19T14:12:00Z")
        let moment = iso("2026-11-19T15:00:00Z")
        let built = build("412", uploaded: upload, external: .waitingForReview, review: .waiting, submitted: sent, groups: [externalGroup])
        let seen = TestFlightObservation(processedSeenAt: iso("2026-11-19T14:11:00Z"))

        let timeline = TestFlightTimeline.make(
            build: built, observation: seen, archiveFinished: iso("2026-11-19T13:59:00Z"), now: moment, calendar: calendar, locale: locale
        )

        #expect(timeline.steps.map(\.id) == ["archive", "upload", "processing", "review", "available"])
        #expect(timeline.steps.map(\.state) == [.done, .done, .done, .done, .upcoming])
        func time(_ string: String) -> String { UsageFormat.time(iso(string), locale: locale) }
        #expect(timeline.steps.map(\.detail) == [
            time("2026-11-19T13:59:00Z"), time("2026-11-19T14:02:00Z"), "seen at \(time("2026-11-19T14:11:00Z"))", time("2026-11-19T14:12:00Z"), "waiting",
        ])
    }

    @Test func aStepThatCannotBeToldIsLeftOutAndAStateWithoutADateHasNoTime() {
        let internalOnly = build("7", internalState: .testing, groups: [internalGroup])

        let timeline = TestFlightTimeline.make(build: internalOnly, observation: nil, archiveFinished: nil, now: now, calendar: calendar, locale: locale)

        #expect(timeline.steps.map(\.id) == ["archive", "upload", "processing", "available"], "no beta review was ever sent")
        #expect(timeline.steps.first?.detail == nil, "no archive time known")
        #expect(timeline.steps[2].detail == nil && timeline.steps[3].detail == nil, "the state alone, no invented hour")
        #expect(timeline.steps.map(\.state) == [.done, .done, .done, .done])

        var unknown = build("8")
        unknown.processing = .unknown
        unknown.internalState = .unknown
        unknown.externalState = .unknown
        let blank = TestFlightTimeline.make(build: unknown, observation: nil, archiveFinished: nil, now: now, calendar: calendar, locale: locale)
        #expect(blank.steps.map(\.id) == ["archive", "upload"])
    }

    @Test func aBuildStillProcessingIsUnderWayAndAnExpiredOneEnds() {
        let processing = build("9", processing: .processing, internalState: .processing, external: .processing)
        let timeline = TestFlightTimeline.make(build: processing, observation: nil, archiveFinished: nil, now: now, calendar: calendar, locale: locale)
        #expect(timeline.steps.map(\.state) == [.done, .done, .current, .upcoming])

        let expired = build("10", expires: now.addingTimeInterval(-86400), internalState: .expired, external: .expired, expired: true)
        let ended = TestFlightTimeline.make(build: expired, observation: nil, archiveFinished: nil, now: now, calendar: calendar, locale: locale)
        #expect(ended.steps.last?.state == .ended)
    }
}

// MARK: - What Cumulus saw change

struct TestFlightObservationTests {
    @Test func aChangeSeenBetweenTwoReadsIsDatedByTheSecond() throws {
        let before = build("1", processing: .processing, internalState: .processing, external: .processing)
        let first = TestFlightReading.following(nil, appID: "a", builds: [before], at: now)
        #expect(first.observations.isEmpty, "a build first seen mid-way says nothing of what came before")

        let processed = build("1", internalState: .ready, external: .readyForSubmission)
        let second = TestFlightReading.following(first, appID: "a", builds: [processed], at: now.addingTimeInterval(900))
        #expect(second.observations["1"]?.processedSeenAt == now.addingTimeInterval(900))
        #expect(second.observations["1"]?.internalAvailableSeenAt == nil)

        let testing = build("1", internalState: .testing, external: .testing, review: .approved)
        let third = TestFlightReading.following(second, appID: "a", builds: [testing], at: now.addingTimeInterval(1800))
        let seen = try #require(third.observations["1"])
        #expect(seen.processedSeenAt == now.addingTimeInterval(900), "an earlier sighting is kept")
        #expect(seen.internalAvailableSeenAt == now.addingTimeInterval(1800) && seen.externalAvailableSeenAt == now.addingTimeInterval(1800))
    }

    @Test func aBuildAlreadyThereAtTheFirstReadHasNoSightingAndAGoneBuildIsForgotten() {
        let ready = build("1")
        let first = TestFlightReading.following(nil, appID: "a", builds: [ready], at: now)
        #expect(first.observations.isEmpty)

        let second = TestFlightReading.following(first, appID: "a", builds: [build("2")], at: now.addingTimeInterval(60))
        #expect(second.observations.isEmpty && second.build(id: "1") == nil)
    }

    @Test func aReadingSurvivesTheDiskAndAnUnknownStateInIt() throws {
        let reading = TestFlightReading.following(nil, appID: "a", builds: [build("1", groups: [externalGroup])], at: now)
        let data = try JSONEncoder().encode(TestFlightFile(readings: ["p1": reading]))
        #expect(try JSONDecoder().decode(TestFlightFile.self, from: data).readings["p1"] == reading)

        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"testing\"", with: "\"from the future\"")
        let decoded = try JSONDecoder().decode(TestFlightFile.self, from: Data(tampered.utf8))
        #expect(decoded.readings["p1"]?.builds.first?.internalState == .unknown)
    }
}

// MARK: - The pace

struct TestFlightCadenceTests {
    private func reading(_ builds: [TestFlightBuild], ageMinutes: Double) -> TestFlightReading {
        TestFlightReading(appID: "app-1", builds: builds, readAt: now.addingTimeInterval(-ageMinutes * 60))
    }

    @Test func anAppNeverReadIsDue() {
        #expect(TestFlightCadence.isDue(app: app, reading: nil, now: now))
    }

    @Test func aQuietAppIsAskedOnceADay() {
        let quiet = reading([build("1", external: .testing)], ageMinutes: 0)
        #expect(!TestFlightCadence.isDue(app: app, reading: reading(quiet.builds, ageMinutes: 23 * 60 + 59), now: now))
        #expect(TestFlightCadence.isDue(app: app, reading: reading(quiet.builds, ageMinutes: 24 * 60), now: now))
    }

    @Test func aBuildBeingProcessedOrWaitingForReviewIsFollowedEveryQuarterHour() {
        for pending in [
            build("1", processing: .processing, internalState: .processing, external: .processing),
            build("2", external: .waitingForReview, review: .waiting),
            build("3", external: .inReview, review: .inReview),
        ] {
            #expect(TestFlightCadence.isPending([pending], now: now))
            #expect(!TestFlightCadence.isDue(app: app, reading: reading([pending], ageMinutes: 14), now: now))
            #expect(TestFlightCadence.isDue(app: app, reading: reading([pending], ageMinutes: 15), now: now))
        }
        #expect(!TestFlightCadence.isPending([build("4", external: .testing), build("5", expired: true)], now: now))
    }

    @Test func aBuildXcodeCloudJustShippedIsLookedForWithoutWaitingADay() {
        var shipping = app
        shipping.newestShippedFinish = now.addingTimeInterval(-20 * 60)
        let old = reading([build("1", uploaded: now.addingTimeInterval(-10 * 86400))], ageMinutes: 16)

        #expect(TestFlightCadence.isDue(app: shipping, reading: old, now: now), "a run finished since the last read")
        let justRead = reading(old.builds, ageMinutes: 5)
        #expect(!TestFlightCadence.isDue(app: shipping, reading: justRead, now: now))
        #expect(TestFlightCadence.isExpectingBuild(app: shipping, builds: old.builds, now: now))

        let arrived = [build("2", uploaded: now.addingTimeInterval(-25 * 60), external: .testing)]
        shipping.newestShippedFinish = now.addingTimeInterval(-20 * 60)
        #expect(!TestFlightCadence.isExpectingBuild(app: shipping, builds: arrived, now: now))
        shipping.newestShippedFinish = now.addingTimeInterval(-2 * 3600)
        #expect(!TestFlightCadence.isExpectingBuild(app: shipping, builds: old.builds, now: now), "after half an hour it is no longer waited for")
        #expect(!TestFlightCadence.isDue(app: shipping, reading: reading(old.builds, ageMinutes: 1), now: now))
    }

    @Test func nothingIsAskedWhenTheHourIsNearlySpentAndAFailureWaitsItsTurn() {
        #expect(!TestFlightCadence.isDue(app: app, reading: nil, now: now, remainingRequests: SyncSchedule.criticalRemaining))
        #expect(TestFlightCadence.isDue(app: app, reading: nil, now: now, remainingRequests: SyncSchedule.criticalRemaining + 1))
        #expect(!TestFlightCadence.isDue(app: app, reading: nil, lastFailure: now.addingTimeInterval(-60), now: now))
        #expect(TestFlightCadence.isDue(app: app, reading: nil, lastFailure: now.addingTimeInterval(-16 * 60), now: now))
    }
}

// MARK: - The banners

struct TestFlightAlertPlannerTests {
    @Test func theFirstReadOnlyRecordsWhatIsInTesting() {
        let builds = [build("412", external: .testing, review: .approved), build("409", external: .testing)]

        let first = TestFlightAlertPlanner.evaluate(app: app, builds: builds, state: TestFlightAlertState(), isBaseline: true, now: now)

        #expect(first.available.isEmpty && first.expiring.isEmpty)
        #expect(first.state.availableReported == ["412", "409"])
    }

    @Test func aBuildThatReachesExternalTestersSpeaksOnce() throws {
        let waiting = [build("412", external: .waitingForReview, review: .waiting)]
        let baseline = TestFlightAlertPlanner.evaluate(app: app, builds: waiting, state: TestFlightAlertState(), isBaseline: true, now: now)
        #expect(baseline.state.availableReported.isEmpty)

        let reached = [build("412", external: .testing, review: .approved, groups: [externalGroup])]
        let news = TestFlightAlertPlanner.evaluate(app: app, builds: reached, state: baseline.state, isBaseline: false, now: now)
        let banner = try #require(news.available.first)
        #expect(news.available.count == 1 && banner.id == "testflight-available-412")
        #expect(banner.title == "Brioche 1.4 (412) is available to external testers" && banner.body == "The beta review passed.")
        #expect(banner.url == CumulusURL.app(productID: "p1") && banner.thread == "p1")

        let again = TestFlightAlertPlanner.evaluate(app: app, builds: reached, state: news.state, isBaseline: false, now: now.addingTimeInterval(900))
        #expect(again.available.isEmpty && again.state == news.state)
    }

    @Test func aBuildOnlyInternalIsNotNewsForExternalTesters() {
        let internalOnly = [build("1", internalState: .testing, external: .readyForSubmission, groups: [internalGroup])]

        let result = TestFlightAlertPlanner.evaluate(app: app, builds: internalOnly, state: TestFlightAlertState(), isBaseline: false, now: now)

        #expect(result.available.isEmpty && result.expiring.isEmpty)
    }

    @Test func theExpiryIsSaidOnceAtSevenDaysForTheBuildTheyAreOn() throws {
        let expiring = build("409", expires: now.addingTimeInterval(6 * 86400 + 3600), external: .testing, review: .approved)
        let farther = build("388", expires: now.addingTimeInterval(8 * 86400), external: .testing)
        let seed = TestFlightAlertState(availableReported: ["409", "388"])

        let early = TestFlightAlertPlanner.evaluate(app: app, builds: [farther], state: seed, isBaseline: false, now: now)
        #expect(early.expiring.isEmpty, "eight days left")

        let result = TestFlightAlertPlanner.evaluate(app: app, builds: [expiring], state: seed, isBaseline: false, now: now, locale: Locale(identifier: "en_US"))
        let banner = try #require(result.expiring.first)
        #expect(banner.id == "testflight-expiry-409" && banner.title == "Brioche: the latest TestFlight build expires in 7 days")
        #expect(banner.body.hasPrefix("After ") && banner.body.hasSuffix(", external testers will have no build to install."))
        #expect(result.state.expiryReported == ["409"])

        let later = TestFlightAlertPlanner.evaluate(app: app, builds: [expiring], state: result.state, isBaseline: false, now: now.addingTimeInterval(86400))
        #expect(later.expiring.isEmpty, "once for each build")
    }

    @Test func aNewerBuildInTestingTakesTheWarningAway() {
        let old = build("1", uploaded: now.addingTimeInterval(-85 * 86400), expires: now.addingTimeInterval(5 * 86400), external: .testing)
        let newer = build("2", uploaded: now.addingTimeInterval(-86400), external: .testing)
        let waiting = build("3", uploaded: now.addingTimeInterval(-3600), external: .waitingForReview, review: .waiting)
        let seed = TestFlightAlertState(availableReported: ["1", "2"])

        let covered = TestFlightAlertPlanner.evaluate(app: app, builds: [newer, old], state: seed, isBaseline: false, now: now)
        #expect(covered.expiring.isEmpty)

        let notYet = TestFlightAlertPlanner.evaluate(app: app, builds: [waiting, old], state: TestFlightAlertState(availableReported: ["1"]), isBaseline: false, now: now)
        #expect(notYet.expiring.map(\.id) == ["testflight-expiry-1"], "a build in review does not reach the testers yet")
    }

    @Test func anExpiredBuildHasNothingToWarnAbout() {
        let gone = build("1", expires: now.addingTimeInterval(-60), internalState: .expired, external: .expired, expired: true)

        let result = TestFlightAlertPlanner.evaluate(app: app, builds: [gone], state: TestFlightAlertState(), isBaseline: false, now: now)

        #expect(result.available.isEmpty && result.expiring.isEmpty)
    }

    @Test func theFirstReadDoesNotSpeakOfAnExpiryAndDoesNotKeepItQuiet() {
        let expiring = build("409", expires: now.addingTimeInterval(3 * 86400), external: .testing)

        let first = TestFlightAlertPlanner.evaluate(app: app, builds: [expiring], state: TestFlightAlertState(), isBaseline: true, now: now)
        #expect(first.expiring.isEmpty && first.state.expiryReported.isEmpty)

        let second = TestFlightAlertPlanner.evaluate(app: app, builds: [expiring], state: first.state, isBaseline: false, now: now.addingTimeInterval(900))
        #expect(second.expiring.count == 1, "it speaks at the next read: a Mac restarted inside the week is still told")
    }

    @Test func whatIsKeptFollowsTheBuildsThatAreRead() {
        let state = TestFlightAlertState(availableReported: ["1", "gone"], expiryReported: ["gone"])

        let result = TestFlightAlertPlanner.evaluate(app: app, builds: [build("1")], state: state, isBaseline: false, now: now)

        #expect(result.state.availableReported == ["1"] && result.state.expiryReported.isEmpty)
    }
}

@MainActor
struct TestFlightCoordinatorTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "TestFlightCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(_ center: MockNotificationCenter, preferences: NotificationPreferences? = nil) -> NotificationCoordinator {
        NotificationCoordinator(
            center: center, preferences: preferences ?? NotificationPreferences(defaults: defaults), defaults: defaults, now: { now }
        )
    }

    private let waiting = [build("412", external: .waitingForReview, review: .waiting)]
    private let reached = [build("412", external: .testing, review: .approved)]

    @Test func theBannerComesOnceAndNeverOnTheFirstReadOfAnApp() async {
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center)

        await coordinator.testFlightDidRead(app: app, builds: reached)
        #expect(await center.posted.isEmpty, "already in testing when the app was first read")

        let other = TestFlightApp(productID: "p2", appID: "app-2", name: "Helm", newestShippedFinish: nil)
        await coordinator.testFlightDidRead(app: other, builds: waiting)
        await coordinator.testFlightDidRead(app: other, builds: reached)
        await coordinator.testFlightDidRead(app: other, builds: reached)
        let posted = await center.posted
        #expect(posted.map(\.title) == ["Helm 1.4 (412) is available to external testers"])
    }

    @Test func whatWasSaidSurvivesARestartAndEachAccountKeepsItsOwn() async throws {
        let center = MockNotificationCenter(status: .allowed)
        let first = makeCoordinator(center)
        await first.testFlightDidRead(app: app, builds: waiting)
        await first.testFlightDidRead(app: app, builds: reached)
        #expect(await center.posted.count == 1)

        let restarted = makeCoordinator(center)
        await restarted.testFlightDidRead(app: app, builds: reached)
        await restarted.testFlightDidRead(app: app, builds: reached)
        #expect(await center.posted.count == 1)

        let key = AccountDefaults.key(AccountDefaults.testFlightAlertState, accountID: AccountRegistry.firstAccountID)
        let stored = try #require(defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: TestFlightAlertState].self, from: $0) })
        #expect(stored["p1"]?.availableReported == ["412"])

        let work = NotificationAccount(id: "second", name: "Work")
        await restarted.testFlightDidRead(account: work, app: app, builds: waiting)
        await restarted.testFlightDidRead(account: work, app: app, builds: reached)
        let posted = await center.posted
        #expect(posted.count == 2 && posted.last?.subtitle == "Work", "its own memory, and its name on the banner")
    }

    @Test func theSettingsAndAMutedAppSilenceTheBannerNotTheMemory() async {
        let preferences = NotificationPreferences(defaults: defaults)
        #expect(preferences.builds.testFlightAvailable && preferences.builds.testFlightExpiry, "both on by default")
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center, preferences: preferences)

        preferences.builds.testFlightAvailable = false
        await coordinator.testFlightDidRead(app: app, builds: waiting)
        await coordinator.testFlightDidRead(app: app, builds: reached)
        preferences.builds.testFlightAvailable = true
        await coordinator.testFlightDidRead(app: app, builds: reached)
        #expect(await center.posted.isEmpty, "turned back on, an old build does not come as news")

        let muted = MockNotificationCenter(status: .allowed)
        preferences.builds.mutedProductIDs = ["p3"]
        let silent = makeCoordinator(muted, preferences: preferences)
        let mutedApp = TestFlightApp(productID: "p3", appID: "app-3", name: "Muted", newestShippedFinish: nil)
        await silent.testFlightDidRead(app: mutedApp, builds: waiting)
        await silent.testFlightDidRead(app: mutedApp, builds: reached)
        #expect(await muted.posted.isEmpty)
    }

    @Test func theExpirySettingSilencesOnlyTheExpiryBanner() async {
        let preferences = NotificationPreferences(defaults: defaults)
        preferences.builds.testFlightExpiry = false
        let center = MockNotificationCenter(status: .allowed)
        let coordinator = makeCoordinator(center, preferences: preferences)
        let nearly = [build("1", expires: now.addingTimeInterval(2 * 86400), external: .testing)]

        await coordinator.testFlightDidRead(app: app, builds: nearly)
        await coordinator.testFlightDidRead(app: app, builds: nearly)
        #expect(await center.posted.isEmpty)

        let reloaded = NotificationPreferences(defaults: defaults)
        #expect(!reloaded.builds.testFlightExpiry && reloaded.builds.testFlightAvailable, "kept across launches")
    }

    @Test func eachAccountOwnsItsMemoryOfWhatWasSaid() {
        #expect(AccountDefaults.names.contains(AccountDefaults.testFlightAlertState))
        defaults.set(Data("{}".utf8), forKey: AccountDefaults.key(AccountDefaults.testFlightAlertState, accountID: "gone"))
        AccountDefaults.removeAll(accountID: "gone", from: defaults)
        #expect(defaults.data(forKey: AccountDefaults.key(AccountDefaults.testFlightAlertState, accountID: "gone")) == nil)
    }
}

// MARK: - The store

@MainActor
struct TestFlightStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "testflight-\(UUID().uuidString)")
    private let clock = TestClock(now)

    private var snapshot: BuildSnapshot {
        var shipping = CIWorkflow(id: "w1", name: "Archive", testDestinationCounts: [])
        shipping.productID = "p1"
        shipping.actions = [CIWorkflowAction(name: "Archive", actionType: .archive, buildDistributionAudience: "APP_STORE_ELIGIBLE")]
        var plain = CIWorkflow(id: "w2", name: "Tests", testDestinationCounts: [])
        plain.productID = "p2"
        var orphan = CIWorkflow(id: "w3", name: "Archive", testDestinationCounts: [])
        orphan.productID = "p3"
        orphan.actions = shipping.actions
        return BuildSnapshot(
            products: [
                CIProduct(id: "p1", name: "Brioche", productType: "APP", appID: "app-1", appName: nil, bundleID: nil),
                CIProduct(id: "p2", name: "Tests only", productType: "APP", appID: "app-2", appName: nil, bundleID: nil),
                CIProduct(id: "p3", name: "No app", productType: "APP", appID: nil, appName: nil, bundleID: nil),
            ],
            workflows: [shipping, plain, orphan], lastSuccessfulSync: now
        )
    }

    private func store(
        transport: MockTransport, budget: RateLimit? = nil, directory: URL? = nil
    ) -> TestFlightStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let store = TestFlightStore(
            cache: TestFlightCache(fileURL: (directory ?? self.directory).appending(path: "TestFlight.json")), client: { client }, budget: { budget },
            now: { [clock] in clock.now }
        )
        return store
    }

    private func answering(_ fixture: String = "testFlightBuilds-macos-review-and-external-group") -> MockTransport {
        MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data(fixture)) ?? Data()) }
    }

    @Test func onlyTheAppsThatShipToTestFlightAreAskedAboutAndOnceADay() async throws {
        let transport = answering()
        let store = store(transport: transport)

        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1, "the app with a shipping workflow and an App Store Connect app")
        #expect(await transport.requests.first?.queryValue("filter[app]") == "app-1")
        let reading = try #require(store.reading(for: "p1"))
        #expect(reading.builds.count == 3 && reading.appID == "app-1" && reading.readAt == now)
        #expect(store.reading(for: "p2") == nil && store.reading(for: "p3") == nil)

        await store.sync(snapshot: snapshot)
        clock.advance(by: 23 * 3600)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1, "a quiet app waits for its day")

        clock.advance(by: 2 * 3600)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 2)
    }

    @Test func aBuildInMotionIsFollowedEveryQuarterHourAndItsChangeIsDatedBySightings() async throws {
        let processing = Data(#"""
        {"data": [{"type": "builds", "id": "b1", "attributes": {"version": "9", "processingState": "PROCESSING", "uploadedDate": "2026-11-19T21:59:00Z", "expirationDate": "2027-02-17T21:59:00Z", "expired": false},
          "relationships": {"buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "b1"}}}}],
         "included": [{"type": "buildBetaDetails", "id": "b1", "attributes": {"internalBuildState": "PROCESSING", "externalBuildState": "PROCESSING"}}]}
        """#.utf8)
        let valid = String(decoding: processing, as: UTF8.self)
            .replacingOccurrences(of: "\"PROCESSING\"", with: "\"VALID\"").replacingOccurrences(of: "\"internalBuildState\": \"VALID\"", with: "\"internalBuildState\": \"IN_BETA_TESTING\"")
            .replacingOccurrences(of: "\"externalBuildState\": \"VALID\"", with: "\"externalBuildState\": \"READY_FOR_BETA_SUBMISSION\"")
        let fixtures = [processing, Data(valid.utf8)]
        let calls = Counter()
        let transport = MockTransport { _ in MockTransport.Reply(body: fixtures[min(calls.next() - 1, 1)]) }
        let store = store(transport: transport)

        await store.sync(snapshot: snapshot)
        clock.advance(by: 10 * 60)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1, "ten minutes is too soon")

        clock.advance(by: 6 * 60)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 2)
        let seen = try #require(store.lookup(buildID: "b1"))
        #expect(seen.build.processing == .valid)
        #expect(seen.observation?.processedSeenAt == clock.now && seen.observation?.internalAvailableSeenAt == clock.now)
    }

    @Test func aReadIsHandedOnForTheBanners() async {
        let store = store(transport: answering())
        var heard: [String] = []
        store.onRead = { app, builds in heard.append("\(app.name):\(app.appID):\(builds.count)") }

        await store.sync(snapshot: snapshot)

        #expect(heard == ["Brioche:app-1:3"])
    }

    @Test func nothingIsAskedWhenTheHourIsNearlySpent() async {
        let transport = answering()
        let store = store(transport: transport, budget: RateLimit(limit: 3600, remaining: SyncSchedule.criticalRemaining))

        await store.sync(snapshot: snapshot)

        #expect(await transport.requests.isEmpty && !store.isReading("p1"))
    }

    @Test func aForbiddenKeyIsRememberedAndNotAskedAgain() async {
        let transport = MockTransport { _ in MockTransport.Reply(status: 403, body: (try? Fixture.data("errorResponse")) ?? Data()) }
        let store = store(transport: transport)

        await store.sync(snapshot: snapshot)
        #expect(store.isForbidden)
        clock.advance(by: 3 * 86400)
        await store.sync(snapshot: snapshot)
        await store.sync(snapshot: snapshot)

        #expect(await transport.requests.count == 1, "no second request for it, whatever the time")
        #expect(store.reading(for: "p1") == nil)
    }

    @Test func aFailureIsTriedAgainAfterAQuarterHourAndKeepsWhatWasKnown() async {
        let calls = Counter()
        let transport = MockTransport { _ in
            calls.next() == 1
                ? MockTransport.Reply(error: URLError(.notConnectedToInternet))
                : MockTransport.Reply(body: (try? Fixture.data("testFlightBuilds-macos-review-and-external-group")) ?? Data())
        }
        let store = store(transport: transport)

        await store.sync(snapshot: snapshot)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1 && store.reading(for: "p1") == nil && !store.isForbidden)

        clock.advance(by: 16 * 60)
        await store.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 2 && store.reading(for: "p1")?.builds.count == 3)
    }

    @Test func whatWasReadStaysOnDiskAndIsNotAskedAgainAfterARestart() async {
        let transport = answering()
        let first = store(transport: transport)
        await first.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1)

        let restarted = store(transport: transport)
        await restarted.loadCache()
        #expect(restarted.reading(for: "p1")?.builds.count == 3)
        await restarted.sync(snapshot: snapshot)
        #expect(await transport.requests.count == 1)

        await restarted.reset()
        #expect(restarted.reading(for: "p1") == nil)
        let afterReset = store(transport: transport)
        await afterReset.loadCache()
        #expect(afterReset.reading(for: "p1") == nil, "the file went with the reset")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func theFileLivesInTheFolderOfTheAccountAndGoesWithIt() {
        let paths = AccountPaths(accountID: "abc", supportRoot: directory, cachesRoot: directory)

        #expect(paths.testFlight.path(percentEncoded: false).hasPrefix(paths.support.path(percentEncoded: false)))
        #expect(paths.testFlight.lastPathComponent == "TestFlight.json")
    }

    @Test func theSkeletonLastsOnlyForAFirstReadThatIsUnderWay() {
        #expect(SkeletonRules.testFlightBuilds(hasBuilds: false, isReading: true))
        #expect(!SkeletonRules.testFlightBuilds(hasBuilds: true, isReading: true), "builds already known are refreshed in place")
        #expect(!SkeletonRules.testFlightBuilds(hasBuilds: false, isReading: false), "a read that ended with nothing leaves no card")
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock {
            $0 += 1
            return $0
        }
    }
}

@MainActor
struct TestFlightAddressTests {
    @Test func anAppAddressNamesAProductAndNothingElse() throws {
        let url = try #require(CumulusURL.app(productID: "abc-123"))

        #expect(url.absoluteString == "cumulus://app/abc-123")
        #expect(CumulusURL.destination(of: url) == .app("abc-123"))
        #expect(CumulusURL.app(productID: "../x") == nil)
        #expect(CumulusURL.destination(of: URL(string: "cumulus://app/a/b")!) == nil)
        #expect(CumulusURL.destination(of: URL(string: "cumulus://app")!) == nil)
    }

    @Test func clickingItShowsTheAppOverview() throws {
        let navigation = NavigationModel()
        let url = try #require(CumulusURL.app(productID: "p1"))

        #expect(navigation.open(url))
        #expect(navigation.sidebarSelection == .product("p1"))
    }
}
