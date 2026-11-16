import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_795_125_600)

private let everyBuild = "a11ce009-0000-4000-8000-000000001009"
private let external = "a11ce00a-0000-4000-8000-00000000100a"
private let qa = "a11ce00e-0000-4000-8000-00000000100e"

private func groups(counts: Bool = true) throws -> [BetaGroup] {
    var all = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<BetaGroupAttributes>.self, from: Fixture.data("betaGroups-app")).betaGroups
    if counts {
        for index in all.indices { all[index].testerCount = [everyBuild: 4, qa: 2, external: 128][all[index].id] }
    }
    return all
}

private func build(
    id: String = "b-412", number: String = "412", age: TimeInterval = 3600, processing: TestFlightProcessing = .valid,
    internalState: TestFlightBetaState = .testing, external externalState: TestFlightBetaState = .readyForSubmission,
    review: TestFlightReviewState? = nil, member: [String] = [], expired: Bool = false, expires: Date? = nil
) -> TestFlightBuild {
    TestFlightBuild(
        id: id, buildNumber: number, marketingVersion: "1.4", platform: "IOS", uploadedDate: now.addingTimeInterval(-age),
        expirationDate: expires ?? now.addingTimeInterval(80 * 86400), isMarkedExpired: expired, processing: processing, internalState: internalState,
        externalState: externalState, review: review, reviewSubmittedDate: nil,
        groups: member.map { TestFlightGroup(name: "?", isInternal: false, id: $0) }, autoNotifyEnabled: nil, betaDetailID: id
    )
}

struct BuildExpirationRequestTests {
    @Test func theBodyCarriesOnlyExpiredTrueAndGoesToTheBuild() throws {
        let request = BuildExpirationRequest(buildID: "b-412")

        let body = try #require(String(data: try request.body(), encoding: .utf8))

        #expect(body == #"{"data":{"attributes":{"expired":true},"id":"b-412","type":"builds"}}"#)
        #expect(!body.contains("false"))
        #expect(AppStoreConnectEndpoint.updateBuild(id: "b-412").path() == "/v1/builds/b-412")
    }

    @Test(arguments: ["", "b/../x", "a b", "é"])
    func aMalformedIdentifierIsNeverSent(id: String) {
        #expect(!BuildExpirationRequest(buildID: id).isWellFormed)
    }

    @Test func theBuildReadAfterAnUnclearAnswerAsksForTheExpiredFlag() throws {
        let query = try #require(URLComponents(url: AppStoreConnectEndpoint.testFlightBuild(id: "b-412"), resolvingAgainstBaseURL: false)?.queryItems)

        let fields = query.first { $0.name == "fields[builds]" }?.value?.split(separator: ",").map(String.init)

        #expect(fields?.contains("expired") == true)
    }
}

struct TestFlightExpirationPresentationTests {
    @Test func theMenuOffersTheExpirationOnlyForAProcessedBuildThatIsNotExpiredWithAWritableKey() {
        #expect(TestFlightExpiration.isOffered(for: build(), canWrite: true, now: now))
        #expect(TestFlightExpiration.isOffered(for: build(internalState: .ready), canWrite: true, now: now))
        #expect(!TestFlightExpiration.isOffered(for: build(), canWrite: false, now: now), "a read-only key")
        #expect(!TestFlightExpiration.isOffered(for: build(processing: .processing), canWrite: true, now: now))
        #expect(!TestFlightExpiration.isOffered(for: build(processing: .failed), canWrite: true, now: now))
        #expect(!TestFlightExpiration.isOffered(for: build(internalState: .processing), canWrite: true, now: now))
        #expect(!TestFlightExpiration.isOffered(for: build(expired: true), canWrite: true, now: now))
        #expect(!TestFlightExpiration.isOffered(for: build(expires: now.addingTimeInterval(-60)), canWrite: true, now: now))
    }

    @Test func theCardModelCarriesTheSameAnswer() throws {
        let all = try groups()

        let open = TestFlightDistributionCardModel.make(build: build(), groups: all, canWrite: true, now: now)
        let readOnly = TestFlightDistributionCardModel.make(build: build(), groups: all, canWrite: false, now: now)
        let expired = TestFlightDistributionCardModel.make(build: build(expired: true), groups: all, canWrite: true, now: now)

        #expect(open.canExpire && !readOnly.canExpire && !expired.canExpire)
        #expect(expired.mode == .expired)
    }

    @Test func theConfirmationNamesTheBuildTheTestersAndTheGroupsAndSaysItCannotBeUndone() throws {
        let all = try groups()
        let target = build(review: .waiting, member: [external, qa])

        let title = TestFlightExpiration.alertTitle(appName: "Brioche", label: target.label)
        let message = TestFlightExpiration.alertMessage(for: target, groups: all)

        #expect(title == "Expire Brioche 1.4 (412)?")
        #expect(message.contains("134 testers"))
        #expect(message.contains("Internal") && message.contains("QA") && message.contains("External testers"))
        #expect(message.contains("The beta review in progress stops."))
        #expect(message.hasSuffix("An expiration can’t be undone."))
    }

    @Test func theConfirmationSaysNothingOfAReviewThatDoesNotExistAndDropsTheCountWhenOneIsUnknown() throws {
        let all = try groups(counts: false)
        let quiet = build(internalState: .testing, external: .readyForSubmission, member: [qa])

        let message = TestFlightExpiration.alertMessage(for: quiet, groups: all)

        #expect(!message.contains("beta review"))
        #expect(message.contains("The testers of") && !message.contains("0 testers"))
        #expect(TestFlightExpiration.alertTitle(appName: nil, label: "1.4 (412)") == "Expire 1.4 (412)?")
        #expect(TestFlightExpiration.alertMessage(for: quiet, groups: []).hasPrefix("No group has this build."))
    }

    @Test func thePreviousBuildIsTheMostRecentOlderOneStillInTestingForAGroup() throws {
        let all = try groups()
        let current = build(id: "b-412", number: "412", age: 3600)
        let newer = build(id: "b-413", number: "413", age: 60)
        let expired = build(id: "b-411", number: "411", age: 7200, expired: true)
        let notTesting = build(id: "b-410", number: "410", age: 10_800, internalState: .ready, external: .readyForSubmission)
        let processing = build(id: "b-409", number: "409", age: 14_400, processing: .processing)
        let target = build(id: "b-408", number: "408", age: 18_000, external: .testing, member: [external])
        let oldest = build(id: "b-407", number: "407", age: 21_600)

        let found = PreviousBuild.find(before: current, among: [newer, current, expired, notTesting, processing, target, oldest], groups: all, now: now)

        #expect(found?.build.id == "b-408", "not the newer build, the expired one, the one in no test, or the one still processing")
        #expect(found?.groupCount == 2, "the internal group that gets every build, and the external one")
        #expect(TestFlightExpiration.previousDetail(groupCount: 3) == "Still in testing for 3 groups. This can’t be undone.")
        #expect(PreviousBuild.find(before: current, among: [newer, current, expired, notTesting], groups: all, now: now) == nil)
        #expect(PreviousBuild.find(before: build(id: "x", age: 1), among: [], groups: all, now: now) == nil)
    }

    @Test func aBuildExpiredByHandIsDatedByTheReadThatSawItNotByAnExpiryDateThatHasNotCome() {
        let before = build()
        let after = build(expired: true)
        let first = TestFlightReading.following(nil, appID: "a", builds: [before], at: now.addingTimeInterval(-600))

        let second = TestFlightReading.following(first, appID: "a", builds: [after], at: now)
        let third = TestFlightReading.following(second, appID: "a", builds: [after], at: now.addingTimeInterval(600))

        #expect(second.observations["b-412"]?.expiredSeenAt == now)
        #expect(third.observations["b-412"]?.expiredSeenAt == now, "kept")
        #expect(TestFlightReading.following(nil, appID: "a", builds: [after], at: now).observations.isEmpty, "a build first seen expired is not dated")
        let locale = Locale(identifier: "en_US")
        #expect(TestFlightText.statusLine(of: after, now: now, expiredSeenAt: now, locale: locale) == TestFlightText.expired(on: now, locale: locale))
        #expect(TestFlightText.statusLine(of: after, now: now, locale: locale) == "Expired", "never a date in the future")
        let aged = build(expired: true, expires: now.addingTimeInterval(-86400))
        #expect(TestFlightText.statusLine(of: aged, now: now, expiredSeenAt: now, locale: locale) == TestFlightText.expired(on: aged.expirationDate, locale: locale))
    }
}

@MainActor
struct TestFlightExpirationServiceTests {
    private final class Log: Sendable {
        let writes = Mutex<[URLRequest]>([])
        let rereads = Mutex<[String]>([])
    }

    private func distributor(
        log: Log, replies: @escaping @Sendable (URLRequest) -> MockTransport.Reply? = { _ in nil },
        reread: @escaping @Sendable (String) -> TestFlightBuild? = { _ in nil }, writable: Bool = true
    ) -> TestFlightDistributor {
        let transport = MockTransport { request in
            log.writes.withLock { $0.append(request) }
            return replies(request) ?? MockTransport.Reply(status: 204)
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return TestFlightDistributor(
            client: { client },
            reread: { id in
                log.rereads.withLock { $0.append(id) }
                return reread(id)
            },
            isKeyWritable: { writable }
        )
    }

    private func shape(_ log: Log) -> [String] {
        log.writes.withLock { $0 }.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" }
    }

    private let refusal = Data(#"{"errors":[{"status":"409","code":"X","title":"Refused","detail":"No."}]}"#.utf8)

    @Test func theExpirationIsOnePatchWithExpiredTrueFollowedByAReadOfTheBuild() async throws {
        let log = Log()
        let after = build(expired: true)

        let outcome = await distributor(log: log, reread: { _ in after }).expire(buildID: "b-412")

        #expect(outcome == .expired(build: after) && outcome.isExpired && outcome.message == nil)
        #expect(shape(log) == ["PATCH /v1/builds/b-412"])
        let sent = try #require(log.writes.withLock { $0.first })
        let body = try #require(sent.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [String: Any]])
        #expect((object["data"]?["attributes"] as? [String: Bool]) == ["expired": true])
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(log.rereads.withLock { $0 } == ["b-412"])
    }

    @Test(arguments: [409, 422])
    func aRefusalShowsApplesWordsAndIsNotRetried(status: Int) async {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: status, body: Data(#"{"errors":[{"status":"\#(status)","code":"X","title":"Refused","detail":"No."}]}"#.utf8)) })
            .expire(buildID: "b-412")

        #expect(outcome == .refused(message: "Refused No.") && outcome.message == "Refused No.")
        #expect(log.writes.withLock { $0.count } == 1 && log.rereads.withLock { $0.isEmpty })
    }

    @Test func aForbiddenKeyIsToldAnAdminOrAppManagerKeyIsNeeded() async {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 403) }).expire(buildID: "b-412")

        #expect(outcome == .notAllowed(message: "This key can’t expire builds. It needs an Admin or App Manager key."))
        #expect(log.writes.withLock { $0.count } == 1)
    }

    @Test func aRateLimitAndANetworkThatNeverLeftTheMacSendNothingMore() async {
        let limited = Log()
        #expect(await distributor(log: limited, replies: { _ in MockTransport.Reply(status: 429) }).expire(buildID: "b-412") == .rateLimited)
        #expect(limited.writes.withLock { $0.count } == 1 && limited.rereads.withLock { $0.isEmpty })

        let offline = Log()
        let outcome = await distributor(log: offline, replies: { _ in MockTransport.Reply(error: URLError(.notConnectedToInternet)) }).expire(buildID: "b-412")
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(offline.rereads.withLock { $0.isEmpty })
    }

    @Test func aTimeoutIsFollowedByAReadNeverByASecondWrite() async {
        let log = Log()
        let still = build()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(error: URLError(.timedOut)) }, reread: { _ in still })
            .expire(buildID: "b-412")

        #expect(outcome == .uncertain(build: still))
        #expect(outcome.message?.contains("look it over before trying again") == true)
        #expect(log.writes.withLock { $0.count } == 1 && log.rereads.withLock { $0 } == ["b-412"])
    }

    @Test func anUnclearAnswerThatTheReadShowsWentThroughIsAnExpiredBuild() async {
        let log = Log()
        let gone = build(expired: true)

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 500) }, reread: { _ in gone }).expire(buildID: "b-412")

        #expect(outcome == .expired(build: gone))
        #expect(log.writes.withLock { $0.count } == 1)
    }

    @Test func anUnclearAnswerAndAReadThatFailsAskToCheckInAppStoreConnect() async {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 500) }).expire(buildID: "b-412")

        #expect(outcome == .uncertain(build: nil))
        #expect(outcome.message?.contains("Check it in App Store Connect before trying again") == true)
    }

    @Test func aReadOnlyKeyOrAMalformedIdentifierSendsNothing() async {
        let readOnly = Log()
        #expect(await distributor(log: readOnly, writable: false).expire(buildID: "b-412") == .notAllowed(message: DistributionOutcome.readOnlyMessage))
        let malformed = Log()
        let outcome = await distributor(log: malformed).expire(buildID: "../x")
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        for log in [readOnly, malformed] {
            #expect(log.writes.withLock { $0.isEmpty } && log.rereads.withLock { $0.isEmpty })
        }
    }

    private func request(add: [String] = [qa]) throws -> DistributionRequest {
        let all = try groups()
        return DistributionRequest(build: build(id: "b-new"), add: try add.map { id in try #require(all.first { $0.id == id }) })
    }

    @Test func theGroupsAreAddedFirstAndTheOldBuildIsExpiredOnlyAfterAppleAcceptedThem() async throws {
        let log = Log()

        let result = await distributor(log: log, reread: { build(id: $0, expired: $0 == "b-old") }).distribute(try request(), thenExpiring: "b-old")

        #expect(shape(log) == ["POST /v1/builds/b-new/relationships/betaGroups", "PATCH /v1/builds/b-old"])
        #expect(result.distribution.isAccepted)
        #expect(result.expiration?.isExpired == true)
        #expect(log.rereads.withLock { $0 }.suffix(1) == ["b-old"])
    }

    @Test func aRefusedAdditionNeverExpiresTheOldBuild() async throws {
        let log = Log()

        let result = await distributor(log: log, replies: { $0.httpMethod == "POST" ? MockTransport.Reply(status: 409, body: refusal) : nil })
            .distribute(try request(), thenExpiring: "b-old")

        #expect(!result.distribution.isAccepted && result.expiration == nil)
        #expect(shape(log) == ["POST /v1/builds/b-new/relationships/betaGroups"])
    }

    @Test func anUnclearAdditionNeverExpiresTheOldBuildEither() async throws {
        let log = Log()

        let result = await distributor(log: log, replies: { _ in MockTransport.Reply(error: URLError(.timedOut)) }).distribute(try request(), thenExpiring: "b-old")

        #expect(result.expiration == nil && log.writes.withLock { $0.count } == 1)
    }

    @Test func aFailedExpirationIsToldApartAndLeavesTheNewBuildAsItIs() async throws {
        let log = Log()

        let result = await distributor(log: log, replies: { $0.httpMethod == "PATCH" ? MockTransport.Reply(status: 409, body: refusal) : nil })
            .distribute(try request(), thenExpiring: "b-old")

        #expect(result.distribution.isAccepted && result.distribution.message == nil)
        #expect(result.expiration == .refused(message: "Refused No."))
        #expect(shape(log) == ["POST /v1/builds/b-new/relationships/betaGroups", "PATCH /v1/builds/b-old"], "no write on the new build after the failure")
    }

    @Test func withoutAPreviousBuildOrWithTheNewBuildItselfNothingIsExpired() async throws {
        let none = Log()
        let alone = await distributor(log: none).distribute(try request(), thenExpiring: nil)
        #expect(alone.distribution.isAccepted && alone.expiration == nil && shape(none) == ["POST /v1/builds/b-new/relationships/betaGroups"])

        let itself = Log()
        let same = await distributor(log: itself).distribute(try request(), thenExpiring: "b-new")
        #expect(same.expiration == nil && itself.writes.withLock { $0.count } == 1, "the new build is never the one that is expired")
    }
}
