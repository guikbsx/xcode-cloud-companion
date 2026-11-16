import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC
private let slackAddress = "https://hooks.slack.com/services/T000/B000/XXXX"
private let genericAddress = "https://example.com/hook"

/// Stands in for the network: records what is sent and answers from a list, the last answer repeating.
private actor RecordingSender: WebhookSending {
    struct Sent {
        var url: URL
        var body: Data
    }

    private(set) var sent: [Sent] = []
    private var answers: [WebhookResult]

    init(_ answers: [WebhookResult] = [.delivered]) {
        self.answers = answers
    }

    func send(_ body: Data, to url: URL) async -> WebhookResult {
        sent.append(Sent(url: url, body: body))
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? .delivered)
    }

    /// The fields of the nth body, every value as its text (a boolean as true or false).
    func json(_ index: Int = 0) -> [String: String] {
        guard sent.indices.contains(index), let object = try? JSONSerialization.jsonObject(with: sent[index].body) as? [String: Any] else { return [:] }
        return object.mapValues { value in
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() { return (value as? Bool) == true ? "true" : "false" }
            return "\(value)"
        }
    }
}

private final class SleepLog: Sendable {
    private let delays = Mutex<[Duration]>([])

    var all: [Duration] { delays.withLock { $0 } }

    func record(_ delay: Duration) {
        delays.withLock { $0.append(delay) }
    }
}

/// A keychain that holds an address but refuses to delete it.
private final class RefusingWebhookAddressStore: WebhookAddressStore {
    func load() async throws(CredentialsStoreError) -> String? { slackAddress }
    func save(_ address: String) async throws(CredentialsStoreError) {}
    func delete() async throws(CredentialsStoreError) { throw .keychain(errSecAuthFailed) }
}

@MainActor
private final class FakeInsights: FailureInsightSource {
    var isOpen = true
    var answer: FailureInsightRecord?

    func record(for run: CIBuildRun, within timeout: Duration) async -> FailureInsightRecord? {
        answer
    }
}

private func run(
    _ number: Int, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded, product: String = "p1",
    createdMinutesAgo: Double = 30, finishedMinutesAgo: Double? = 1
) -> CIBuildRun {
    let created = now.addingTimeInterval(-createdMinutesAgo * 60)
    return CIBuildRun(
        id: "run-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
        finishedDate: progress == .complete ? finishedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) } : nil,
        executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil,
        workflowID: "w1", workflowName: "Release", sourceBranchOrTag: "main"
    )
}

private func snapshot(_ runs: [CIBuildRun], actions: [String: [CIBuildAction]] = [:], syncedMinutesAgo: Double? = 0) -> BuildSnapshot {
    BuildSnapshot(
        products: [
            CIProduct(id: "p1", name: "Cumulus", productType: "APP", appID: nil, appName: nil, bundleID: nil),
            CIProduct(id: "p2", name: "Helm", productType: "APP", appID: nil, appName: nil, bundleID: nil),
        ],
        runs: runs, actionsByRunID: actions, lastSuccessfulSync: syncedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
    )
}

private func action(_ id: String, run runNumber: Int, progress: CIExecutionProgress = .complete, startedMinutesAgo: Double, ranFor minutes: Double? = nil) -> CIBuildAction {
    let started = now.addingTimeInterval(-startedMinutesAgo * 60)
    return CIBuildAction(
        id: id, buildRunID: "run-\(runNumber)", name: "Test - iOS", actionType: .test, startedDate: started,
        finishedDate: minutes.map { started.addingTimeInterval($0 * 60) }, executionProgress: progress,
        completionStatus: progress == .complete ? .succeeded : nil, isRequiredToPass: true
    )
}

private func usage(used: Double, cycle: Int = 0, estimated: Double = 0) -> UsageSummary {
    let day: TimeInterval = 24 * 3600
    let start = now.addingTimeInterval(-25 * day + Double(cycle) * 30 * day)
    let moment = start.addingTimeInterval(25 * day)
    return UsageSummary(
        plan: UsagePlan(hours: 25, resetAnchor: start), cycle: DateInterval(start: start, duration: 30 * day), now: moment,
        billedMinutes: used - estimated, estimatedMinutes: estimated, estimatedBuildCount: estimated > 0 ? 3 : 0, lastImport: moment, daily: [], buildsLast30Days: 0, byApp: [],
        measurement: MeasurementProgress()
    )
}

struct WebhookAddressTests {
    @Test func onlyAnHTTPSAddressWithAHostIsKept() throws {
        #expect(try WebhookAddress(slackAddress).host == "hooks.slack.com")
        #expect(try WebhookAddress("  HTTPS://Example.com/hook \n").host == "example.com")
        #expect(throws: WebhookAddressError.notHTTPS) { try WebhookAddress("http://example.com/hook") }
        #expect(throws: WebhookAddressError.notHTTPS) { try WebhookAddress("ftp://example.com/hook") }
        #expect(throws: WebhookAddressError.invalid) { try WebhookAddress("") }
        #expect(throws: WebhookAddressError.invalid) { try WebhookAddress("https://") }
        #expect(throws: WebhookAddressError.invalid) { try WebhookAddress("example.com/hook") }
        #expect(throws: WebhookAddressError.invalid) { try WebhookAddress("https://exa mple.com/hook") }
    }

    @Test func theHostDecidesTheKindOfMessage() throws {
        #expect(try WebhookAddress(slackAddress).kind == .slack)
        #expect(try WebhookAddress("https://discord.com/api/webhooks/1/abc").kind == .discord)
        #expect(try WebhookAddress("https://ptb.discord.com/api/webhooks/1/abc").kind == .discord)
        #expect(try WebhookAddress("https://discord.com/channels/1").kind == .generic, "only the webhook path of Discord")
        #expect(try WebhookAddress(genericAddress).kind == .generic)
        #expect(try WebhookAddress("https://hooks.slack.com.example.com/x").kind == .generic)
    }

    @Test func onlyTheHostEverShows() throws {
        let address = try WebhookAddress(slackAddress)

        #expect(address.masked == "hooks.slack.com/••••••••")
        for text in [address.description, address.debugDescription, "\(address)", String(reflecting: address.host)] {
            #expect(!text.contains("XXXX") && !text.contains("services"))
        }
    }
}

struct WebhookMessageTests {
    private let banner = LocalNotification(
        id: "build-run-42", title: "Cumulus #42 failed", subtitle: "Tests · Release", body: "Two login tests fail.", url: CumulusURL.build(id: "run-42"), thread: "p1"
    )

    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theTextIsTheBannerThenTheAddressOnALineOfItsOwn() {
        let message = WebhookMessage(event: .buildFailed, banner: banner, account: nil)

        #expect(message.text == "Cumulus #42 failed\nTests · Release\nTwo login tests fail.\ncumulus://build/run-42")
        let bare = WebhookMessage(event: .buildSucceeded, title: "Cumulus #42 succeeded", body: "Release · main", url: CumulusURL.build(id: "run-42"))
        #expect(bare.text == "Cumulus #42 succeeded\nRelease · main\ncumulus://build/run-42")
    }

    @Test func slackGetsTextAndDiscordGetsContent() throws {
        let message = WebhookMessage(event: .buildFailed, banner: banner, account: nil)

        #expect(try decode(message.json(for: .slack)) as NSDictionary == ["text": message.text] as NSDictionary)
        #expect(try decode(message.json(for: .discord)) as NSDictionary == ["content": message.text] as NSDictionary)
    }

    @Test func discordMessagesStopAtItsLimit() throws {
        let long = WebhookMessage(event: .buildFailed, title: "Title", body: String(repeating: "x", count: 5_000))

        let content = try #require(try decode(long.json(for: .discord))["content"] as? String)
        #expect(content.count == WebhookMessage.discordLimit)
    }

    @Test func anyOtherAddressGetsTheDocumentedFields() throws {
        let message = WebhookMessage(
            event: .buildFailed, banner: banner, account: "Work", context: WebhookContext(app: "Cumulus", workflow: "Release", build: 42)
        )

        let json = try decode(message.json(for: .generic))
        #expect(Set(json.keys) == ["event", "title", "body", "app", "workflow", "build", "url", "isEstimate", "text", "account"])
        #expect(json["event"] as? String == "build_failed")
        #expect(json["title"] as? String == "Cumulus #42 failed")
        #expect(json["body"] as? String == "Two login tests fail.")
        #expect(json["app"] as? String == "Cumulus")
        #expect(json["workflow"] as? String == "Release")
        #expect(json["build"] as? Int == 42)
        #expect(json["url"] as? String == "cumulus://build/run-42")
        #expect(json["isEstimate"] as? Bool == false)
        #expect(json["text"] as? String == message.text)
        #expect(json["account"] as? String == "Work")
    }

    @Test func aMessageWithoutAppWorkflowBuildOrAccountLeavesThemOut() throws {
        let message = WebhookMessage(event: .usageAlert, title: "75% of your Xcode Cloud plan used", body: "~22 h 30 of 25 h", context: WebhookContext(isEstimate: true))

        let json = try decode(message.json(for: .generic))
        #expect(Set(json.keys) == ["event", "title", "body", "isEstimate", "text"])
        #expect(json["isEstimate"] as? Bool == true)
    }

    @Test func theTestMessageSaysItIsOne() throws {
        let message = WebhookMessage.test(account: nil)

        #expect(message.text.hasPrefix("Test from Cumulus"))
        #expect(try decode(message.json(for: .generic))["event"] as? String == "test")
        #expect(WebhookChoices().includes(.test) == false)
    }

    @Test func theChoicesStartWithTheThreeAlertsOn() {
        let choices = WebhookChoices()

        #expect(choices.includes(.usageAlert) && choices.includes(.buildStuck) && choices.includes(.buildFailed))
        #expect(!choices.includes(.buildSucceeded))
    }

    @Test func theLastSendNamesTheOutcomeAndNeverTheAddress() {
        let locale = Locale(identifier: "en_US")
        #expect(WebhookText.lastSend(.delivered, at: now, locale: locale).hasPrefix("Last send: sent · "))
        #expect(WebhookText.lastSend(.refused(404), at: now, locale: locale).hasPrefix("Last send: refused, 404 · "))
        #expect(WebhookText.lastSend(.unreachable, at: now, locale: locale).hasPrefix("Last send: could not be reached · "))
        #expect(!WebhookResult.delivered.isRetryable && !WebhookResult.refused(404).isRetryable)
        #expect(WebhookResult.refused(503).isRetryable && WebhookResult.unreachable.isRetryable)
    }

    @Test func theAddressRowWaitsForTheKeychainOnly() {
        #expect(SkeletonRules.webhookAddress(hasLoaded: false))
        #expect(!SkeletonRules.webhookAddress(hasLoaded: true))
    }
}

@MainActor
struct WebhookSettingsModelTests {
    private let accounts = TestAccounts()

    @Test func anAddressIsKeptInTheKeychainAndNeverInThePreferences() async throws {
        let session = try await accounts.add("Work")
        #expect(await session.webhook.commit("  \(slackAddress)\n"))

        #expect(session.webhook.hasAddress && session.webhook.maskedAddress == "hooks.slack.com/••••••••")
        #expect(accounts.webhookStore(session.id).current == slackAddress)
        let everything = accounts.defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!everything.contains("XXXX") && !everything.contains("services/T000"))
        #expect(await session.webhook.address()?.url == URL(string: slackAddress))
    }

    @Test func anAddressThatIsNotHTTPSIsRefusedAndNothingIsKept() async throws {
        let session = try await accounts.add("Work")

        #expect(await session.webhook.commit("http://example.com/hook") == false)
        #expect(session.webhook.addressError == .notHTTPS)
        #expect(!session.webhook.hasAddress && accounts.webhookStore(session.id).current == nil)
        #expect(await session.webhook.commit("nothing") == false)
        #expect(session.webhook.addressError == .invalid)

        #expect(await session.webhook.commit(genericAddress))
        #expect(session.webhook.addressError == nil)
    }

    @Test func replacingKeepsTheOldAddressUntilTheNewOneIsAccepted() async throws {
        let session = try await accounts.add("Work")
        await session.webhook.commit(slackAddress)

        #expect(await session.webhook.commit("http://example.com/hook") == false)
        #expect(session.webhook.host == "hooks.slack.com")
        #expect(await session.webhook.commit(genericAddress))
        #expect(session.webhook.host == "example.com" && accounts.webhookStore(session.id).current == genericAddress)
    }

    @Test func anEmptyFieldRemovesTheAddress() async throws {
        let session = try await accounts.add("Work")
        await session.webhook.commit(slackAddress)

        #expect(await session.webhook.commit("   "))
        #expect(!session.webhook.hasAddress && accounts.webhookStore(session.id).current == nil)
    }

    @Test func theChoicesSurviveARestartAndBelongToTheirAccount() async throws {
        let work = try await accounts.add("Work")
        let home = try await accounts.add("Home")
        #expect(home.webhook.choices == WebhookChoices())
        work.webhook.choices.succeeded = true
        work.webhook.choices.usage = false

        let restarted = WebhookSettingsModel(accountID: work.id, store: accounts.webhookStore(work.id), defaults: accounts.defaults)
        #expect(restarted.choices == WebhookChoices(usage: false, stuck: true, failed: true, succeeded: true))
        #expect(home.webhook.choices == WebhookChoices())
    }

    @Test func forgettingAnAccountDeletesItsAddressAndItsChoices() async throws {
        let session = try await accounts.add("Work")
        await session.webhook.commit(slackAddress)
        session.webhook.choices.succeeded = true

        #expect(await accounts.model.remove(session.id))

        #expect(accounts.webhookStore(session.id).current == nil)
        for name in [AccountDefaults.webhookEvents, AccountDefaults.webhookUsageAlertState] {
            #expect(accounts.defaults.object(forKey: AccountDefaults.key(name, accountID: session.id)) == nil)
        }
        #expect(AccountDefaults.names.contains(AccountDefaults.webhookEvents) && AccountDefaults.names.contains(AccountDefaults.webhookUsageAlertState))
    }

    @Test func aKeychainThatKeepsTheAddressKeepsTheAccount() async throws {
        let account = Account(id: "work", name: "Work")
        let paths = accounts.paths(account.id)
        let store = accounts.keychain(account.id)
        let session = AccountSession(
            account: account, paths: paths,
            settings: SettingsModel(accountID: account.id, store: store, defaults: accounts.defaults),
            buildStore: BuildStore(credentialsStore: store, cacheStore: BuildCacheStore(fileURL: paths.buildCache)),
            usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(cache: BuildExtrasCache(directory: paths.buildDetails), client: { nil }),
            defaults: accounts.defaults, webhookAddresses: RefusingWebhookAddressStore()
        )
        try await store.save(TestAccounts.credentials)

        #expect(await session.erase() == false)
        #expect(session.webhook.errorMessage != nil)
        #expect(try await store.load() != nil, "the key stays with the account")
    }
}

@MainActor
struct WebhookServiceTests {
    private let accounts = TestAccounts()
    private let sleeps = SleepLog()

    private func service(_ sender: RecordingSender) -> WebhookService {
        WebhookService(accounts: accounts.model, sender: sender, sleep: { [sleeps] in sleeps.record($0) }, now: { now })
    }

    private func account(address: String? = slackAddress) async throws -> AccountSession {
        let session = try await accounts.add("Work")
        if let address { await session.webhook.commit(address) }
        return session
    }

    private func message(_ event: WebhookEvent = .buildFailed) -> WebhookMessage {
        WebhookMessage(event: event, title: "Cumulus #42 failed", body: "Release · main", url: CumulusURL.build(id: "run-42"))
    }

    @Test func onlyTheChosenEventsGoToTheSavedAddressInItsShape() async throws {
        let session = try await account()
        let sender = RecordingSender()
        let webhook = service(sender)

        webhook.send([message(.buildFailed), message(.buildSucceeded), message(.usageAlert)], accountID: session.id)
        await webhook.settle()

        let sent = await sender.sent
        #expect(sent.count == 2, "a successful build is not chosen by default")
        #expect(sent.allSatisfy { $0.url == URL(string: slackAddress) })
        #expect(await sender.json(0)["text"] == message().text)
        #expect(webhook.delivery(for: session.id) == WebhookService.Delivery(date: now, result: .delivered))
    }

    @Test func anOtherHostGetsTheGenericShape() async throws {
        let session = try await account(address: genericAddress)
        let sender = RecordingSender()
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)
        await webhook.settle()

        #expect(await sender.json()["event"] == "build_failed")
    }

    @Test func aServerErrorIsTriedOnceMoreThirtySecondsLater() async throws {
        let session = try await account()
        let sender = RecordingSender([.refused(503), .delivered])
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)
        await webhook.settle()

        #expect(await sender.sent.count == 2)
        #expect(sleeps.all == [.seconds(30)])
        #expect(webhook.delivery(for: session.id)?.result == .delivered)
    }

    @Test func aNetworkErrorIsTriedOnceMoreAndOnlyOnce() async throws {
        let session = try await account()
        let sender = RecordingSender([.unreachable])
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)
        await webhook.settle()

        #expect(await sender.sent.count == 2)
        #expect(webhook.delivery(for: session.id)?.result == .unreachable)
    }

    @Test func aRefusalIsNotTriedAgain() async throws {
        let session = try await account()
        let sender = RecordingSender([.refused(404)])
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)
        await webhook.settle()

        #expect(await sender.sent.count == 1 && sleeps.all.isEmpty)
        #expect(webhook.delivery(for: session.id)?.result == .refused(404))
    }

    @Test func aSendDoesNotWaitForTheAnswer() async throws {
        let session = try await account()
        let sender = RecordingSender([.refused(503)])
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)

        #expect(webhook.delivery(for: session.id) == nil, "send returns before anything is answered")
        await webhook.settle()
    }

    @Test func anAddressRemovedDuringTheWaitIsNotSentToAgain() async throws {
        let session = try await account()
        let sender = RecordingSender([.unreachable])
        let webhook = WebhookService(accounts: accounts.model, sender: sender, sleep: { _ in _ = await session.webhook.remove() }, now: { now })

        webhook.send([message()], accountID: session.id)
        await webhook.settle()

        #expect(await sender.sent.count == 1)
    }

    @Test func withoutAnAddressNothingGoes() async throws {
        let session = try await account(address: nil)
        let sender = RecordingSender()
        let webhook = service(sender)

        webhook.send([message()], accountID: session.id)
        await webhook.settle()
        await webhook.sendTest(accountID: session.id)

        #expect(await sender.sent.isEmpty && webhook.delivery(for: session.id) == nil)
    }

    @Test func theTestIsOneAttemptMarkedAsATestWhateverTheChoices() async throws {
        let session = try await account(address: genericAddress)
        session.webhook.choices = WebhookChoices(usage: false, stuck: false, failed: false, succeeded: false)
        let sender = RecordingSender([.refused(500)])
        let webhook = service(sender)

        await webhook.sendTest(accountID: session.id)

        #expect(await sender.sent.count == 1 && sleeps.all.isEmpty)
        #expect((await sender.json()["title"])?.hasPrefix("Test from Cumulus") == true)
        #expect(await sender.json()["event"] == "test")
        #expect(webhook.delivery(for: session.id)?.result == .refused(500))
    }

    @Test func theAccountNameGoesOnlyWithSeveralAccounts() async throws {
        let only = try await account(address: genericAddress)
        let sender = RecordingSender()
        let webhook = service(sender)
        await webhook.sendTest(accountID: only.id)
        #expect(await sender.json()["account"] == nil)

        let other = try await accounts.add("Home")
        await other.webhook.commit(genericAddress)
        await webhook.sendTest(accountID: other.id)
        #expect(await sender.json(1)["account"] == "Home")
    }
}

@MainActor
struct WebhookCoordinatorTests {
    private let accounts = TestAccounts()
    private let defaults: UserDefaults
    private let center = MockNotificationCenter(status: .allowed)
    private let sender = RecordingSender()
    private let running = snapshot([run(42, progress: .running), run(43, progress: .running, product: "p2")], syncedMinutesAgo: 1)

    init() {
        defaults = accounts.defaults
    }

    private func setUp(
        address: String? = slackAddress, choices: WebhookChoices = WebhookChoices(), configure: (NotificationPreferences) -> Void = { _ in }
    ) async throws -> (NotificationCoordinator, WebhookService, NotificationAccount, AccountSession) {
        let session = try await accounts.add("Work")
        if let address { await session.webhook.commit(address) }
        session.webhook.choices = choices
        let preferences = NotificationPreferences(defaults: defaults)
        configure(preferences)
        let webhook = WebhookService(accounts: accounts.model, sender: sender, sleep: { _ in }, now: { now })
        let coordinator = NotificationCoordinator(
            center: center, preferences: preferences, defaults: defaults, failureWait: .seconds(5), webhook: webhook, now: { now }
        )
        return (coordinator, webhook, NotificationAccount(id: session.id, name: nil), session)
    }

    private func sync(_ coordinator: NotificationCoordinator, _ account: NotificationAccount, from previous: BuildSnapshot? = nil, to current: BuildSnapshot, insights: (any FailureInsightSource)? = nil) async {
        await coordinator.buildsDidSync(account: account, previous: .empty, current: previous ?? running, insights: insights)
        await coordinator.buildsDidSync(account: account, previous: previous ?? running, current: current, insights: insights)
        await coordinator.settleFailureBanners()
    }

    private let failedAndSucceeded = snapshot([run(42, status: .failed), run(43, product: "p2")])

    @Test func aFailedBuildGoesWithTheWordsOfItsBanner() async throws {
        let (coordinator, webhook, account, _) = try await setUp()

        await sync(coordinator, account, to: failedAndSucceeded)
        await webhook.settle()

        let banner = try #require(await center.posted.first { $0.id == "build-run-42" })
        let json = await sender.json()
        #expect(await sender.sent.count == 1, "the successful build is not chosen")
        #expect(json["text"] == "\(banner.title)\n\(banner.body)\n\(banner.url?.absoluteString ?? "")")
    }

    @Test func theWebhookChoosesIndependentlyOfTheBanners() async throws {
        let (coordinator, webhook, account, _) = try await setUp(choices: WebhookChoices(usage: true, stuck: true, failed: true, succeeded: true)) {
            $0.builds.failed = false
            $0.builds.succeeded = false
        }

        await sync(coordinator, account, to: failedAndSucceeded)
        await webhook.settle()

        #expect(await center.posted.isEmpty, "the banners are off")
        #expect(await sender.sent.count == 2, "the webhook is told of both")
        let events = [await sender.json(0)["text"], await sender.json(1)["text"]].compactMap(\.self)
        #expect(events.contains { $0.hasPrefix("Cumulus #42 failed") } && events.contains { $0.hasPrefix("Helm #43 succeeded") })
    }

    @Test func aBannerOnWithTheWebhookOffSendsNothing() async throws {
        let (coordinator, webhook, account, _) = try await setUp(choices: WebhookChoices(usage: false, stuck: false, failed: false, succeeded: false))

        await sync(coordinator, account, to: failedAndSucceeded)
        await webhook.settle()

        #expect(await center.posted.count == 2)
        #expect(await sender.sent.isEmpty)
    }

    @Test func theGuardsOfTheBannersHoldForTheWebhookToo() async throws {
        let (coordinator, webhook, account, _) = try await setUp(choices: WebhookChoices(usage: true, stuck: true, failed: true, succeeded: true)) {
            $0.builds.mutedProductIDs = ["p2"]
        }
        let old = snapshot([run(42, status: .failed, finishedMinutesAgo: 90)])

        await coordinator.buildsDidSync(account: account, previous: running, current: failedAndSucceeded)
        #expect(await sender.sent.isEmpty, "the first sync of an account only says where things stand")
        await sync(coordinator, account, to: failedAndSucceeded)
        await webhook.settle()

        let texts = [await sender.json(0)["text"]].compactMap(\.self)
        #expect(await sender.sent.count == 1 && texts.first?.hasPrefix("Cumulus #42 failed") == true, "the muted app says nothing")

        let (otherCoordinator, otherWebhook, otherAccount, _) = try await setUp(choices: WebhookChoices(usage: true, stuck: true, failed: true, succeeded: true))
        await sync(otherCoordinator, otherAccount, to: old)
        await otherWebhook.settle()
        #expect(await sender.sent.count == 1, "a build that ended more than an hour ago is old news")
    }

    @Test func aStuckBuildIsSentOnce() async throws {
        var runs = (1...3).map { run($0, createdMinutesAgo: 600, finishedMinutesAgo: 500) }
        var actions = Dictionary(uniqueKeysWithValues: (1...3).map { ("run-\($0)", [action("a\($0)", run: $0, startedMinutesAgo: 600, ranFor: 10)]) })
        runs.insert(run(42, progress: .running), at: 0)
        actions["run-42"] = [action("live", run: 42, progress: .running, startedMinutesAgo: 45)]
        let stuck = snapshot(runs, actions: actions)
        let (coordinator, webhook, account, _) = try await setUp(choices: WebhookChoices(usage: true, stuck: true, failed: false, succeeded: false)) {
            $0.builds.stuck = false
        }

        await coordinator.buildsDidSync(account: account, previous: .empty, current: stuck)
        await coordinator.buildsDidSync(account: account, previous: stuck, current: stuck)
        await coordinator.buildsDidSync(account: account, previous: stuck, current: stuck)
        await webhook.settle()

        #expect(await center.posted.isEmpty, "the banner for a stuck build is off")
        #expect(await sender.sent.count == 1)
        #expect((await sender.json()["text"])?.hasPrefix("Cumulus #42 may be stuck") == true)
    }

    @Test func eachThresholdOfThePlanIsSentOncePerCycleWhateverTheBannersChose() async throws {
        let (coordinator, webhook, account, _) = try await setUp {
            $0.usage.threshold75 = false
            $0.usage.threshold90 = false
            $0.usage.pace = false
        }
        let empty = BuildSnapshot(lastSuccessfulSync: now)
        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: nil)

        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: usage(used: 1_130))
        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: usage(used: 1_130))
        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: usage(used: 1_360))
        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: usage(used: 1_360, cycle: 1))
        await webhook.settle()

        #expect(await center.posted.isEmpty)
        var titles: [String] = []
        for index in 0..<(await sender.sent.count) {
            titles.append(await sender.json(index)["text"] ?? "")
        }
        #expect(titles.filter { $0.hasPrefix("75%") }.count == 1, "once, then a threshold below the one that spoke is settled")
        #expect(titles.filter { $0.hasPrefix("90%") }.count == 2, "once in each cycle")
    }

    @Test func aFigureThatIsAnEstimateSaysSoInTheMessage() async throws {
        let (coordinator, webhook, account, _) = try await setUp(address: genericAddress)
        let empty = BuildSnapshot(lastSuccessfulSync: now)
        let estimated = usage(used: 1_130, estimated: 300)
        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: nil)

        await coordinator.buildsDidSync(account: account, previous: empty, current: empty, summary: estimated)
        await webhook.settle()

        let json = await sender.json()
        #expect(json["isEstimate"] == "true")
        #expect((json["body"])?.contains("Estimated from your builds") == true)
        #expect(json["event"] == "usage_alert")
    }

    @Test func aCanceledBuildAndASlowdownNeverGoToTheWebhook() async throws {
        let (coordinator, webhook, account, _) = try await setUp(choices: WebhookChoices(usage: true, stuck: true, failed: true, succeeded: true)) {
            $0.builds.canceled = true
        }

        await sync(coordinator, account, to: snapshot([run(42, status: .canceled)]))
        await webhook.settle()

        #expect(await center.posted.map(\.id) == ["build-run-42"])
        #expect(await sender.sent.isEmpty)
    }

    @Test func aFailedBuildCarriesItsInsightWhenTheBannerDoes() async throws {
        let (coordinator, webhook, account, _) = try await setUp(address: genericAddress) {
            $0.builds.failed = false
        }
        let insights = FakeInsights()
        insights.answer = FailureInsightRecord(category: .tests, headline: "Two login tests fail.")

        await sync(coordinator, account, to: failedAndSucceeded, insights: insights)
        await webhook.settle()

        let json = await sender.json()
        #expect(await center.posted.map(\.id) == ["build-run-43"], "the banner for a failure is off")
        #expect(json["body"] == "Two login tests fail.")
        #expect((json["text"])?.contains("Tests · Release") == true)
        #expect(json["workflow"] == "Release" && json["build"] == "42" && json["app"] == "Cumulus")
        #expect(await sender.sent.count == 1)
    }

    @Test func severalAccountsPutTheAccountNameInTheMessage() async throws {
        let (coordinator, webhook, _, session) = try await setUp(address: genericAddress)
        let named = NotificationAccount(id: session.id, name: "Work")

        await sync(coordinator, named, to: failedAndSucceeded)
        await webhook.settle()

        let json = await sender.json()
        #expect(json["account"] == "Work")
        #expect((json["text"])?.contains("\nWork\n") == true)
    }

    @Test func noWebhookLeavesTheBannersAsTheyWere() async throws {
        let preferences = NotificationPreferences(defaults: defaults)
        let coordinator = NotificationCoordinator(center: center, preferences: preferences, defaults: defaults, now: { now })

        await sync(coordinator, NotificationAccount(), to: failedAndSucceeded)

        #expect(await center.posted.map(\.id).sorted() == ["build-run-42", "build-run-43"])
    }
}
