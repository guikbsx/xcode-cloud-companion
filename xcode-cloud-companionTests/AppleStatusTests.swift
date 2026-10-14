import AppKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

/// 2026-10-04 12:41 UTC, when the one real event seen on the page began.
private let t0 = Date(timeIntervalSince1970: 1_791_117_660)
private let minute: TimeInterval = 60

private func page(events: String, service: String = "Xcode Cloud") -> Data {
    Data("jsonCallback({\"drMessage\":null,\"services\":[{\"serviceName\":\"\(service)\",\"events\":[\(events)]}],\"drpost\":false});".utf8)
}

private func ended(from start: Date, to end: Date) -> String {
    "{\"epochStartDate\":\(Int(start.timeIntervalSince1970 * 1000)),\"epochEndDate\":\(Int(end.timeIntervalSince1970 * 1000)),\"eventStatus\":\"resolved\"}"
}

private func ongoing(from start: Date) -> String {
    "{\"epochStartDate\":\(Int(start.timeIntervalSince1970 * 1000)),\"eventStatus\":\"ongoing\"}"
}

private func run(
    _ number: Int, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .errored, startedAt: Date? = nil, finishedAt: Date? = nil,
    createdAt: Date? = nil
) -> CIBuildRun {
    CIBuildRun(
        id: "run-\(number)", productID: "p1", number: number, createdDate: createdAt ?? startedAt, startedDate: startedAt, finishedDate: finishedAt,
        executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: "w1", workflowName: "Release",
        sourceBranchOrTag: "main"
    )
}

private func snapshot(_ runs: [CIBuildRun], syncedAt: Date?) -> BuildSnapshot {
    BuildSnapshot(products: [], runs: runs, actionsByRunID: [:], lastSuccessfulSync: syncedAt)
}

// MARK: - Decoding

struct AppleStatusDecoderTests {
    @Test func theRealPageWithXcodeCloudQuietIsNoEvent() throws {
        let reading = AppleStatusDecoder.decode(try Fixture.data("appleSystemStatus-resolved-elsewhere"))

        #expect(reading == .events([]), "the real resolved event sits on another service and is not Xcode Cloud's")
    }

    @Test func anOngoingIncidentOnXcodeCloudIsAnAssumedShapeNotYetSeenOnTheRealPage() throws {
        let reading = AppleStatusDecoder.decode(try Fixture.data("appleSystemStatus-assumed-ongoing"))

        #expect(reading == .events([AppleStatusEvent(start: Date(timeIntervalSince1970: 1_791_117_660), end: nil)]))
    }

    @Test func aResolvedEventKeepsItsEnd() {
        let end = t0.addingTimeInterval(200 * minute)
        let reading = AppleStatusDecoder.decode(page(events: ended(from: t0, to: end)))

        #expect(reading == .events([AppleStatusEvent(start: t0, end: end)]))
    }

    @Test(arguments: [
        "\"epochEndDate\":null,", "\"epochEndDate\":0,", "", "\"epochEndDate\":-1,",
    ])
    func noEndOrANullOrZeroEndMeansItGoesOnWhateverTheStatusSays(endField: String) {
        let json = "{\"epochStartDate\":1791117660000,\(endField)\"eventStatus\":\"resolved\"}"

        #expect(AppleStatusDecoder.decode(page(events: json)) == .events([AppleStatusEvent(start: t0, end: nil)]))
    }

    @Test func theServiceNameIsMatchedWithoutItsStrayBlanks() {
        let reading = AppleStatusDecoder.decode(page(events: ongoing(from: t0), service: " Xcode Cloud "))

        #expect(reading == .events([AppleStatusEvent(start: t0, end: nil)]))
    }

    @Test func aPlainJSONBodyWithoutTheCallbackIsReadToo() {
        let body = Data("{\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[]}]}".utf8)

        #expect(AppleStatusDecoder.decode(body) == .events([]))
    }

    @Test(arguments: [
        "", "not json", "jsonCallback(", "jsonCallback();", "jsonCallback([]);", "jsonCallback({});", "jsonCallback({\"services\":{}});",
        "jsonCallback({\"services\":[]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Account\",\"events\":[]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\"}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":{}}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[3]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[{}]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[{\"epochStartDate\":\"1791117660000\"}]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[{\"epochStartDate\":true}]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[{\"epochStartDate\":0}]}]});",
        "jsonCallback({\"services\":[{\"serviceName\":\"Xcode Cloud\",\"events\":[{\"epochStartDate\":1791117660000,\"epochEndDate\":\"soon\"}]}]});",
    ])
    func anythingUnexpectedIsUnknownAndNeverAnError(body: String) {
        #expect(AppleStatusDecoder.decode(Data(body.utf8)) == .unknown)
    }

    @Test func bytesThatAreNotTextAreUnknown() {
        #expect(AppleStatusDecoder.decode(Data([0xFF, 0xFE, 0x00])) == .unknown)
    }

    @Test func oneUnreadableEventAmongGoodOnesMakesThePageUnknown() {
        let reading = AppleStatusDecoder.decode(page(events: ended(from: t0, to: t0.addingTimeInterval(60)) + ",{\"message\":\"x\"}"))

        #expect(reading == .unknown, "an event Cumulus cannot read could be the one that matters")
    }
}

// MARK: - Covering a stop

struct AppleStatusCoverageTests {
    private let event = AppleStatusEvent(start: t0, end: t0.addingTimeInterval(60 * minute))

    @Test func aBuildThatStoppedInsideTheEventIsCovered() {
        #expect(event.covers(from: t0 + 10 * minute, to: t0 + 22 * minute, now: t0 + 500 * minute))
    }

    @Test func aBuildThatStartedBeforeAndEndedInsideIsCovered() {
        #expect(event.covers(from: t0 - 30 * minute, to: t0 + 12 * minute, now: t0 + 500 * minute))
    }

    @Test func aBuildThatEndedBeforeTheEventOrStartedAfterItIsNot() {
        #expect(!event.covers(from: t0 - 30 * minute, to: t0 - 1 * minute, now: t0 + 500 * minute))
        #expect(!event.covers(from: t0 + 61 * minute, to: t0 + 70 * minute, now: t0 + 500 * minute))
    }

    @Test func theEdgesCount() {
        #expect(event.covers(from: t0 - 5 * minute, to: t0, now: t0 + 500 * minute))
        #expect(event.covers(from: t0 + 60 * minute, to: t0 + 65 * minute, now: t0 + 500 * minute))
    }

    @Test func anEventStillGoingOnLastsUntilNow() {
        let open = AppleStatusEvent(start: t0, end: nil)

        #expect(open.covers(from: t0 + 100 * minute, to: t0 + 110 * minute, now: t0 + 120 * minute))
        #expect(!open.covers(from: t0 - 20 * minute, to: t0 - 10 * minute, now: t0 + 120 * minute))
    }

    @Test func theEventCoveringARunIsFoundFromItsLife() {
        let knowledge = AppleStatusKnowledge(events: [event], readAt: t0 + 70 * minute)
        let inside = run(1, startedAt: t0 + 5 * minute, finishedAt: t0 + 22 * minute)
        let before = run(2, startedAt: t0 - 40 * minute, finishedAt: t0 - 20 * minute)
        let neverStarted = run(3, startedAt: nil, finishedAt: t0 + 30 * minute, createdAt: t0 + 28 * minute)

        #expect(knowledge.event(covering: inside, now: t0 + 80 * minute) == event)
        #expect(knowledge.event(covering: before, now: t0 + 80 * minute) == nil)
        #expect(knowledge.event(covering: neverStarted, now: t0 + 80 * minute) == event)
    }

    @Test func withSeveralEventsTheEarliestOneIsTheAnswer() {
        let later = AppleStatusEvent(start: t0 + 10 * minute, end: nil)
        let knowledge = AppleStatusKnowledge(events: [later, event], readAt: t0 + 20 * minute)

        #expect(knowledge.event(covering: run(1, startedAt: t0 + 12 * minute, finishedAt: t0 + 15 * minute), now: t0 + 20 * minute) == event)
    }

    @Test func whatIsKnownOfAnIncidentGoingOnExpiresButAClosedOneStays() {
        let open = AppleStatusEvent(start: t0, end: nil)
        let knowledge = AppleStatusKnowledge(events: [open, AppleStatusEvent(start: t0 - 500 * minute, end: t0 - 400 * minute)], readAt: t0)

        #expect(knowledge.ongoing(at: t0 + 29 * minute) == open)
        #expect(knowledge.ongoing(at: t0 + 31 * minute) == nil)
        #expect(knowledge.current(at: t0 + 31 * minute).count == 1)
    }
}

// MARK: - Cadence

struct AppleStatusScheduleTests {
    @Test func theAddressIsTheExactOneAndReadsNeedTenMinutesBetweenThem() {
        #expect(AppleStatusSchedule.address.absoluteString == "https://www.apple.com/support/systemstatus/data/developer/system_status_en_US.js")
        #expect(AppleStatusSchedule.mayRead(lastAttempt: nil, now: t0))
        #expect(!AppleStatusSchedule.mayRead(lastAttempt: t0, now: t0 + 9 * minute + 59))
        #expect(AppleStatusSchedule.mayRead(lastAttempt: t0, now: t0 + 10 * minute))
        #expect(AppleStatusSchedule.mayRead(lastAttempt: t0, now: t0 - 5 * minute), "a clock set back does not lock the page")
    }

    @Test func theSheetReadsOnlyForABuildThatEndedInErrorLessThanADayAgo() {
        let now = t0 + 30 * 3600
        #expect(AppleStatusSchedule.sheetOpensRead(run: run(1, finishedAt: now - 23 * 3600), now: now))
        #expect(!AppleStatusSchedule.sheetOpensRead(run: run(2, finishedAt: now - 25 * 3600), now: now))
        #expect(!AppleStatusSchedule.sheetOpensRead(run: run(3, status: .failed, finishedAt: now - 60), now: now))
        #expect(!AppleStatusSchedule.sheetOpensRead(run: run(4, status: .succeeded, finishedAt: now - 60), now: now))
        #expect(!AppleStatusSchedule.sheetOpensRead(run: run(5, progress: .running), now: now))
        #expect(!AppleStatusSchedule.sheetOpensRead(run: run(6, finishedAt: nil), now: now))
    }

    @Test func aSyncSeesABuildEndInErrorOnlyWhenItWasRunningBefore() {
        let now = t0 + 100 * minute
        let before = snapshot([run(1, progress: .running, startedAt: now - 30 * minute)], syncedAt: now - minute)
        let after = snapshot([run(1, startedAt: now - 30 * minute, finishedAt: now - 10)], syncedAt: now)

        #expect(AppleStatusSchedule.erroredFinishes(previous: before, current: after, now: now).map(\.id) == ["run-1"])
        #expect(AppleStatusSchedule.erroredFinishes(previous: after, current: after, now: now).isEmpty)
    }

    @Test func aBuildCreatedAndErroredBetweenTwoSyncsCountsButNotAnOldOne() {
        let now = t0 + 100 * minute
        let before = snapshot([], syncedAt: now - 2 * minute)
        let fresh = run(1, startedAt: now - 90, finishedAt: now - 20, createdAt: now - 100)
        let old = run(2, startedAt: now - 3 * 3600, finishedAt: now - 2 * 3600, createdAt: now - 3 * 3600)

        #expect(AppleStatusSchedule.erroredFinishes(previous: before, current: snapshot([fresh, old], syncedAt: now), now: now).map(\.id) == ["run-1"])
    }

    @Test func otherEndingsAndTheFirstLoadAreNotTriggers() {
        let now = t0 + 100 * minute
        let before = snapshot([run(1, progress: .running), run(2, progress: .running)], syncedAt: now - minute)
        let after = snapshot([run(1, status: .failed, finishedAt: now - 5), run(2, status: .succeeded, finishedAt: now - 5)], syncedAt: now)

        #expect(AppleStatusSchedule.erroredFinishes(previous: before, current: after, now: now).isEmpty)
        let firstLoad = snapshot([], syncedAt: nil)
        #expect(AppleStatusSchedule.erroredFinishes(previous: firstLoad, current: snapshot([run(3, finishedAt: now - 5)], syncedAt: now), now: now).isEmpty)
    }

    @Test func buildsThatEndedInErrorDuringTheIncidentAreCountedOverEveryAccount() {
        let interval = DateInterval(start: t0, end: t0 + 60 * minute)
        let first = snapshot([
            run(1, finishedAt: t0 + 10 * minute), run(2, status: .failed, finishedAt: t0 + 20 * minute), run(3, finishedAt: t0 + 90 * minute),
            run(4, finishedAt: t0 + 60 * minute),
        ], syncedAt: nil)
        let second = snapshot([run(5, finishedAt: t0 - 1), run(6, finishedAt: t0), run(7, progress: .running)], syncedAt: nil)

        #expect(AppleStatusSchedule.erroredBuilds(in: [first, second], during: interval) == 3)
        #expect(AppleStatusSchedule.erroredBuilds(in: [], during: interval) == 0)
    }

    @Test func aWatchEndsOnlyOnAPageThatListsNothingGoingOn() {
        let since = t0
        func outcome(_ reading: AppleStatusReading?, after: TimeInterval) -> AppleStatusSchedule.WatchOutcome {
            AppleStatusSchedule.watchOutcome(reading: reading, incidentStart: t0 - 10 * minute, watchingSince: since, now: since + after)
        }
        let closed = AppleStatusEvent(start: t0 - 10 * minute, end: t0 + 40 * minute)

        #expect(outcome(.events([AppleStatusEvent(start: t0 - 10 * minute, end: nil)]), after: 600) == .keepWatching)
        #expect(outcome(.events([closed]), after: 3000) == .resolved(DateInterval(start: t0 - 10 * minute, end: t0 + 40 * minute)))
        #expect(outcome(.events([]), after: 3000) == .resolved(DateInterval(start: t0 - 10 * minute, end: t0 + 3000)))
        #expect(outcome(.unknown, after: 600) == .keepWatching, "a page Cumulus cannot read is no news")
        #expect(outcome(nil, after: 600) == .keepWatching, "nor is a failed read")
    }

    @Test func aWatchStopsAfterTwelveHours() {
        let open = AppleStatusReading.events([AppleStatusEvent(start: t0, end: nil)])

        #expect(AppleStatusSchedule.watchOutcome(reading: open, incidentStart: t0, watchingSince: t0, now: t0 + 12 * 3600 - 1) == .keepWatching)
        #expect(AppleStatusSchedule.watchOutcome(reading: open, incidentStart: t0, watchingSince: t0, now: t0 + 12 * 3600) == .expired)
        #expect(AppleStatusSchedule.watchOutcome(reading: .unknown, incidentStart: t0, watchingSince: t0, now: t0 + 13 * 3600) == .expired)
    }
}

// MARK: - The request

struct AppleStatusRequestTests {
    @Test func theRequestIsABareGETWithNothingOfTheUser() throws {
        let request = URLSessionAppleStatusFetcher.request

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == AppleStatusSchedule.address.absoluteString)
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        #expect((request.allHTTPHeaderFields ?? [:]).isEmpty)
        #expect(!request.httpShouldHandleCookies)
    }

    @Test func theSessionKeepsNoCookieNoCacheNoCredential() {
        let configuration = URLSessionAppleStatusFetcher.makeSession().configuration

        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}

// MARK: - Words

struct AppleStatusFormatTests {
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    private let paris = TimeZone(identifier: "Europe/Paris")!

    @Test func theTimesAreTheMacsZoneNotApplesAndAnOngoingIncidentSaysSince() {
        let event = AppleStatusEvent(start: t0, end: nil)
        let now = t0 + 90 * minute

        let utcBanner = AppleStatusFormat.banner(for: event, stoppedAt: t0 + 10 * minute, now: now, locale: english, timeZone: utc)
        let parisBanner = AppleStatusFormat.banner(for: event, stoppedAt: t0 + 10 * minute, now: now, locale: english, timeZone: paris)

        #expect(utcBanner.title.hasPrefix("Apple reports an incident on Xcode Cloud since 12:41"))
        #expect(parisBanner.title.hasPrefix("Apple reports an incident on Xcode Cloud since 2:41"))
        #expect(utcBanner.detail.contains("This build stopped at 12:51"))
        #expect(utcBanner.detail.hasSuffix("According to Apple’s system status page."))
    }

    @Test func aClosedIncidentGivesBothTimesAndAnotherDayShowsTheDate() {
        let event = AppleStatusEvent(start: t0, end: t0 + 3 * 3600)
        let banner = AppleStatusFormat.banner(for: event, stoppedAt: nil, now: t0 + 2 * 86_400, locale: english, timeZone: utc)

        #expect(banner.title.hasPrefix("Apple reported an incident on Xcode Cloud, from Oct 4"))
        #expect(banner.title.contains("to Oct 4"))
        #expect(banner.detail == "According to Apple’s system status page.", "no stop time, no sentence about it")
    }

    @Test func theNoticeNeverQuotesApplesOwnText() {
        let banner = AppleStatusFormat.banner(for: AppleStatusEvent(start: t0, end: nil), stoppedAt: t0, now: t0, locale: english, timeZone: utc)

        #expect(!banner.title.contains("Some users") && !banner.detail.contains("Some users"))
    }

    @Test func theRecoveryBannerCountsTheBuildsAndOpensTheList() {
        let two = AppleStatusFormat.recoveryNotification(erroredBuilds: 2, locale: english)
        let one = AppleStatusFormat.recoveryNotification(erroredBuilds: 1, locale: english)
        let none = AppleStatusFormat.recoveryNotification(erroredBuilds: 0, locale: english)

        #expect(two.title == "Xcode Cloud is back")
        #expect(two.body == "The incident reported by Apple is over. 2 builds stopped during that time.")
        #expect(one.body == "The incident reported by Apple is over. 1 build stopped during that time.")
        #expect(none.body == "The incident reported by Apple is over.")
        #expect(two.url == CumulusURL.builds)
    }

    @Test func theFrenchNoticeAndBannerAreWritten() {
        let french = Locale(identifier: "fr_FR")
        let banner = AppleStatusFormat.banner(for: AppleStatusEvent(start: t0, end: nil), stoppedAt: t0 + 10 * minute, now: t0 + 90 * minute, locale: french, timeZone: paris)
        let recovered = AppleStatusFormat.recoveryNotification(erroredBuilds: 2, locale: french)

        #expect(banner.title.hasPrefix("Apple signale un incident sur Xcode Cloud depuis 14"))
        #expect(banner.detail.hasPrefix("Ce build s’est arrêté à 14"))
        #expect(banner.detail.hasSuffix("D’après la page d’état des services d’Apple."))
        #expect(recovered.title == "Xcode Cloud est rétabli")
        #expect(recovered.body == "L’incident signalé par Apple est clos. 2 builds se sont arrêtés pendant ce temps.")
        #expect(AppleStatusFormat.menuLine(locale: french) == "Xcode Cloud : incident en cours chez Apple")
    }

    @Test @MainActor func theListOfBuildsHasAnAddressThatOpensIt() throws {
        let url = try #require(CumulusURL.builds)
        let navigation = NavigationModel()
        navigation.sidebarSelection = .overview
        navigation.selectedBuildID = "r1"

        #expect(CumulusURL.destination(of: url) == .builds)
        #expect(CumulusURL.destination(of: URL(string: "cumulus://builds/x")!) == nil)
        #expect(navigation.open(url))
        #expect(navigation.sidebarSelection == .allBuilds && navigation.selectedBuildID == nil)
    }
}

// MARK: - The menu

@MainActor
struct AppleStatusMenuTests {
    private func items(incident: Bool, open: @escaping () -> Void = {}) -> [NSMenuItem] {
        var state = StatusMenuState(needsAPIKey: false, isSyncing: false, now: t0)
        state.hasAppleIncident = incident
        return StatusMenuBuilder.items(for: state, actions: StatusMenuActions(openAppleStatusPage: open))
    }

    @Test func anIncidentGoingOnGetsALineAtTheTopSaidInWords() throws {
        let line = try #require(items(incident: true).first)

        #expect(line.attributedTitle?.string == "\u{25B2} Xcode Cloud: incident in progress at Apple")
        #expect(items(incident: true)[1].isSeparatorItem)
    }

    @Test func withoutAnIncidentTheMenuSaysNothingAboutApple() {
        #expect(!items(incident: false).contains { $0.title.contains("incident") })
    }

    @Test func theLineOpensTheStatusPage() throws {
        var opened = false
        let line = try #require(items(incident: true, open: { opened = true }).first)

        _ = (line.target as? MenuActionTarget)?.run(nil)

        #expect(opened)
        #expect(AppleStatusSchedule.statusPage.absoluteString == "https://developer.apple.com/system-status/")
    }
}

// MARK: - The store

private actor ScriptedFetcher: AppleStatusFetching {
    private var replies: [Result<Data, any Error>]
    private(set) var count = 0

    init(_ replies: [Result<Data, any Error>]) {
        self.replies = replies
    }

    func fetch() async throws -> Data {
        count += 1
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        return try (replies.count > 1 ? replies.removeFirst() : replies[0]).get()
    }
}

private final class Outbox: Sendable {
    private let state = Mutex<(banners: [LocalNotification], authorizations: Int, intervals: [DateInterval])>(([], 0, []))

    var banners: [LocalNotification] { state.withLock { $0.banners } }
    var authorizations: Int { state.withLock { $0.authorizations } }
    var intervals: [DateInterval] { state.withLock { $0.intervals } }

    func post(_ banners: [LocalNotification]) { state.withLock { $0.banners += banners } }
    func authorize() { state.withLock { $0.authorizations += 1 } }
    func count(_ interval: DateInterval) -> Int {
        state.withLock {
            $0.intervals.append(interval)
            return 2
        }
    }
}

@MainActor
struct AppleStatusStoreTests {
    private let clock = TestClock(t0 + 30 * minute)
    private let outbox = Outbox()

    private func store(_ fetcher: (any AppleStatusFetching)?, pinned: [AppleStatusEvent]? = nil) -> AppleStatusStore {
        let clock = clock
        let outbox = outbox
        return AppleStatusStore(
            fetcher: fetcher, notify: { outbox.post($0) }, requestAuthorization: { outbox.authorize() }, erroredBuilds: { outbox.count($0) },
            pinned: pinned, now: { clock.now }, sleep: { _ in clock.advance(by: 300) }
        )
    }

    private let incident = page(events: ongoing(from: t0))
    private let quiet = page(events: "")

    private func erroredSync(_ store: AppleStatusStore, account: String = "a") async {
        let now = clock.now
        let before = snapshot([run(1, progress: .running, startedAt: now - 20 * minute)], syncedAt: now - minute)
        let after = snapshot([run(1, startedAt: now - 20 * minute, finishedAt: now - 5)], syncedAt: now)
        await store.buildsDidSync(accountID: account, previous: before, current: after)
    }

    @Test func theFirstSyncOfAnAccountReadsNothingAndTheNextErroredBuildDoes() async {
        let fetcher = ScriptedFetcher([.success(incident)])
        let store = store(fetcher)

        await erroredSync(store)
        #expect(await fetcher.count == 0)

        await erroredSync(store)
        #expect(await fetcher.count == 1)
        #expect(store.ongoingIncident(at: clock.now)?.start == t0)
    }

    @Test func aSyncWithoutAnErroredBuildReadsNothingAndNothingReadsInTheBackground() async {
        let fetcher = ScriptedFetcher([.success(incident)])
        let store = store(fetcher)
        let now = clock.now
        let before = snapshot([run(1, progress: .running)], syncedAt: now - minute)
        let after = snapshot([run(1, status: .succeeded, finishedAt: now - 5)], syncedAt: now)

        await store.buildsDidSync(accountID: "a", previous: before, current: after)
        await store.buildsDidSync(accountID: "a", previous: before, current: after)

        #expect(await fetcher.count == 0)
        #expect(store.knowledge == nil)
    }

    @Test func readsAreTenMinutesApartWhateverTriggersThem() async {
        let fetcher = ScriptedFetcher([.success(incident)])
        let store = store(fetcher)
        let errored = run(7, startedAt: clock.now - 20 * minute, finishedAt: clock.now - 60)

        await store.sheetDidOpen(for: errored)
        await store.sheetDidOpen(for: errored)
        await erroredSync(store)
        await erroredSync(store)
        #expect(await fetcher.count == 1)

        clock.advance(by: 10 * minute)
        await store.sheetDidOpen(for: errored)
        #expect(await fetcher.count == 2)
    }

    @Test func aFailedReadCountsAsAnAttemptAndLeavesWhatWasKnown() async {
        let fetcher = ScriptedFetcher([.success(incident), .failure(URLError(.timedOut)), .success(page(events: "garbage"))])
        let store = store(fetcher)
        let errored = run(7, startedAt: clock.now - 20 * minute, finishedAt: clock.now - 60)

        await store.sheetDidOpen(for: errored)
        clock.advance(by: 10 * minute)
        await store.sheetDidOpen(for: errored)
        clock.advance(by: 10 * minute)
        await store.sheetDidOpen(for: errored)

        #expect(await fetcher.count == 3)
        #expect(store.knowledge?.events == [AppleStatusEvent(start: t0, end: nil)], "neither a failure nor an unreadable page erases it")
    }

    @Test func theSheetOfABuildThatIsNotAnOldEnoughErrorReadsNothing() async {
        let fetcher = ScriptedFetcher([.success(incident)])
        let store = store(fetcher)

        await store.sheetDidOpen(for: run(1, status: .failed, finishedAt: clock.now - 60))
        await store.sheetDidOpen(for: run(2, finishedAt: clock.now - 30 * 3600))

        #expect(await fetcher.count == 0)
    }

    @Test func withoutAFetcherNothingIsReadAndNothingIsKnown() async {
        let store = store(nil)

        await store.sheetDidOpen(for: run(1, finishedAt: clock.now - 60))

        #expect(store.knowledge == nil && store.ongoingIncident(at: clock.now) == nil)
    }

    @Test func onlyABuildThatEndedInErrorUnderAnEventGetsTheNotice() async {
        let fetcher = ScriptedFetcher([.success(incident)])
        let store = store(fetcher)
        let inside = run(1, startedAt: t0 + 5 * minute, finishedAt: t0 + 22 * minute)
        await store.sheetDidOpen(for: inside)

        #expect(store.event(covering: inside, at: clock.now)?.start == t0)
        #expect(store.event(covering: run(2, status: .failed, startedAt: t0 + 5 * minute, finishedAt: t0 + 22 * minute), at: clock.now) == nil)
        #expect(store.event(covering: run(3, startedAt: t0 - 60 * minute, finishedAt: t0 - 30 * minute), at: clock.now) == nil)
    }

    @Test func theIncidentFromAReadIsForgottenAfterHalfAnHour() async {
        let store = store(ScriptedFetcher([.success(incident)]))
        await store.sheetDidOpen(for: run(1, finishedAt: clock.now - 60))

        #expect(store.ongoingIncident(at: clock.now + 29 * minute) != nil)
        #expect(store.ongoingIncident(at: clock.now + 31 * minute) == nil)
    }

    @Test func aWatchReadsEveryFiveMinutesAndSaysWhenItIsOverWithTheCount() async throws {
        let closed = page(events: ended(from: t0, to: t0 + 50 * minute))
        let fetcher = ScriptedFetcher([.success(incident), .success(incident), .success(page(events: "garbage")), .success(incident), .success(closed)])
        let store = store(fetcher)
        await store.sheetDidOpen(for: run(1, finishedAt: clock.now - 60))
        let event = try #require(store.ongoingIncident(at: clock.now))

        store.startWatching(event)
        #expect(store.isWatching)
        await store.settleWatch()

        #expect(await fetcher.count == 5)
        #expect(!store.isWatching)
        #expect(outbox.authorizations == 1)
        #expect(outbox.banners.count == 1)
        #expect(outbox.banners.first?.title == "Xcode Cloud is back")
        #expect(outbox.banners.first?.body.contains("2 builds") == true)
        #expect(outbox.intervals == [DateInterval(start: t0, end: t0 + 50 * minute)])
        #expect(store.ongoingIncident(at: clock.now) == nil)
    }

    @Test func aWatchThatNeverGetsAReadablePageStopsAfterTwelveHoursWithoutABanner() async throws {
        let fetcher = ScriptedFetcher([.success(incident), .failure(URLError(.notConnectedToInternet))])
        let store = store(fetcher)
        await store.sheetDidOpen(for: run(1, finishedAt: clock.now - 60))

        store.startWatching(try #require(store.ongoingIncident(at: clock.now)))
        await store.settleWatch()

        #expect(!store.isWatching)
        #expect(outbox.banners.isEmpty)
        #expect(await fetcher.count == 1 + 12 * 12, "one read every five minutes for twelve hours")
    }

    @Test func aWatchIsAskedForOnceAndOnlyForAnIncidentGoingOn() async throws {
        let store = store(ScriptedFetcher([.success(incident)]))
        store.startWatching(AppleStatusEvent(start: t0, end: t0 + 60))
        #expect(!store.isWatching, "a closed incident has nothing to wait for")

        store.startWatching(AppleStatusEvent(start: t0, end: nil))
        store.startWatching(AppleStatusEvent(start: t0, end: nil))
        await store.settleWatch()
        #expect(outbox.authorizations == 1)
    }

    @Test func aPinnedStateIsKnownWithoutReadingAndNeverGrowsOld() {
        let events = AppleStatusStore.pinnedEvents(named: "incident", now: clock.now)
        let store = store(nil, pinned: events)

        #expect(store.ongoingIncident(at: clock.now + 5 * 86_400) != nil)
        #expect(AppleStatusStore.pinnedEvents(named: "resolved", now: clock.now)?.first?.isOngoing == false)
        #expect(AppleStatusStore.pinnedEvents(named: "nonsense", now: clock.now) == nil)
        #expect(AppleStatusStore.pinnedEvents(named: nil, now: clock.now) == nil)
    }
}
