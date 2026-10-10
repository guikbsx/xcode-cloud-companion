import CryptoKit
import Foundation
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private func apiReply(_ request: URLRequest) -> MockTransport.Reply {
    let path = request.url?.path() ?? ""
    let fixture: String? = switch path {
    case "/v1/ciProducts": "ciProducts"
    case "/v1/ciProducts/product-1/buildRuns": request.queryValue("cursor") == nil ? "ciBuildRuns-page1" : "ciBuildRuns-page2"
    case let path where path.hasSuffix("/workflows"): "ciWorkflows"
    case let path where path.hasSuffix("/testResults"): "ciTestResults"
    case let path where path.hasPrefix("/v1/ciBuildRuns/"): "ciBuildActions"
    default: nil
    }
    guard let fixture else { return MockTransport.Reply(body: Data(#"{"data": [], "links": {}}"#.utf8)) }
    return MockTransport.Reply(body: (try? Fixture.data(fixture)) ?? Data())
}

private func requestCount(_ transport: MockTransport, matching predicate: (String) -> Bool) async -> Int {
    await transport.requests.compactMap { $0.url?.path() }.filter(predicate).count
}

struct BuildSynchronizerTests {
    @Test func firstSyncLoadsAppsBuildsInTheWindowAndTheirActions() async throws {
        let transport = MockTransport(reply: apiReply)
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let snapshot = try await synchronizer.sync(from: .empty, now: now)

        #expect(snapshot.products.map(\.id) == ["product-1", "product-2"])
        #expect(snapshot.runs.map(\.number) == [42, 41, 40])
        #expect(Set(snapshot.actionsByRunID.keys) == ["run-42", "run-41", "run-40"])
        #expect(snapshot.lastSuccessfulSync == now)
        #expect(snapshot.hasActiveBuilds)
        #expect(snapshot.workflows.map(\.name) == ["Release", "Pull Requests", "Release", "Pull Requests"])
        #expect(Set(snapshot.testDevicesByActionID.keys) == ["action-test"])
        #expect(snapshot.testDevicesByActionID["action-test"]?.count == 3)
        // products + 2 workflows + 3 build-run pages + 3 action lists + 1 test-results request (one action id, asked once)
        #expect(await transport.requests.count == 10)
    }

    @Test func laterSyncsOnlyAskForNewAndRunningBuilds() async throws {
        let transport = MockTransport(reply: apiReply)
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))
        let first = try await synchronizer.sync(from: .empty, now: now)
        let requestsAfterFirstSync = await transport.requests.count

        let second = try await synchronizer.sync(from: first, now: now.addingTimeInterval(60))

        #expect(second.runs.map(\.number) == [42, 41, 40])
        #expect(second.actionsByRunID == first.actionsByRunID)
        let newRequests = await Array(transport.requests.dropFirst(requestsAfterFirstSync)).compactMap { $0.url?.path() }
        #expect(newRequests.filter { $0.hasSuffix("/actions") } == ["/v1/ciBuildRuns/run-42/actions"])
        #expect(newRequests.filter { $0 == "/v1/ciProducts/product-1/buildRuns" }.count == 1)
        #expect(newRequests.filter { $0.hasSuffix("/testResults") }.isEmpty)
    }

    @Test func testResultsAreFetchedInBatchesAndReportedAsPending() async throws {
        let runsJSON = (1...15).map { number in
            #"{"type": "ciBuildRuns", "id": "run-\#(number)", "attributes": {"number": \#(number), "createdDate": "2026-10-0\#(number % 9 + 1)T10:00:00Z", "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}}"#
        }.joined(separator: ",")
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if path == "/v1/ciProducts/product-1/buildRuns" {
                return MockTransport.Reply(body: Data(#"{"data": [\#(runsJSON)], "links": {}}"#.utf8))
            }
            if path.hasPrefix("/v1/ciBuildRuns/run-"), path.hasSuffix("/actions") {
                let number = path.dropFirst("/v1/ciBuildRuns/run-".count).prefix { $0.isNumber }
                return MockTransport.Reply(body: Data(#"{"data": [{"type": "ciBuildActions", "id": "test-\#(number)", "attributes": {"actionType": "TEST", "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}}], "links": {}}"#.utf8))
            }
            return apiReply(request)
        }
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let first = try await synchronizer.sync(from: .empty, now: now)

        #expect(first.runs.count == 15)
        #expect(await requestCount(transport) { $0.hasSuffix("/testResults") } == 12)
        #expect(BuildSynchronizer.pendingTestResultCount(in: first) == 3)
    }

    @Test func aFailingTestResultRequestDoesNotFailTheSync() async throws {
        let transport = MockTransport { request in
            request.url?.path().hasSuffix("/testResults") == true ? MockTransport.Reply(status: 500) : apiReply(request)
        }
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let snapshot = try await synchronizer.sync(from: .empty, now: now)

        #expect(snapshot.runs.count == 3)
        #expect(snapshot.testDevicesByActionID.isEmpty)
    }

    @Test func buildsLeavingTheWindowAreDropped() async throws {
        let transport = MockTransport(reply: apiReply)
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))
        let first = try await synchronizer.sync(from: .empty, now: now)

        let monthLater = try await synchronizer.sync(from: first, now: now.addingTimeInterval(20 * 86_400))

        #expect(monthLater.runs.map(\.number) == [42, 41])
        #expect(monthLater.actionsByRunID["run-40"] == nil)
    }

    @Test func refreshStartsFromTheNewestBuildUnlessAnOlderOneIsStillRunning() {
        let windowStart = Date(timeIntervalSince1970: 0)
        func run(_ number: Int, createdAt seconds: TimeInterval, _ progress: CIExecutionProgress) -> CIBuildRun {
            CIBuildRun(id: "\(number)", productID: "p", number: number, createdDate: Date(timeIntervalSince1970: seconds), startedDate: nil, finishedDate: nil, executionProgress: progress, completionStatus: nil, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil)
        }

        #expect(BuildSynchronizer.refreshStart(for: [], windowStart: windowStart) == windowStart)
        #expect(BuildSynchronizer.refreshStart(for: [run(3, createdAt: 300, .complete), run(2, createdAt: 200, .complete)], windowStart: windowStart) == Date(timeIntervalSince1970: 300))
        #expect(BuildSynchronizer.refreshStart(for: [run(3, createdAt: 300, .complete), run(2, createdAt: 200, .running)], windowStart: windowStart) == Date(timeIntervalSince1970: 200))
    }

    @Test func snapshotsSurviveACacheRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json"))
        let transport = MockTransport(reply: apiReply)
        let snapshot = try await BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport)).sync(from: .empty, now: now)

        try await cache.save(snapshot)
        #expect(await cache.load() == snapshot)

        await cache.delete()
        #expect(await cache.load() == nil)
    }
}

@MainActor
struct BuildStoreTests {
    private let pem = P256.Signing.PrivateKey().pemRepresentation

    private func makeStore(
        credentials: InMemoryCredentialsStore? = nil,
        cache: BuildCacheStore = BuildCacheStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/BuildCache.json")),
        transport: MockTransport
    ) -> BuildStore {
        BuildStore(
            credentialsStore: credentials ?? InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem)),
            cacheStore: cache,
            makeClient: { AppStoreConnectClient(credentials: $0, transport: transport) },
            now: { now }
        )
    }

    @Test func aSuccessfulSyncIsPublishedAndCached() async {
        let cache = BuildCacheStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/BuildCache.json"))
        let store = makeStore(cache: cache, transport: MockTransport(reply: apiReply))

        let outcome = await store.synchronize()

        #expect(outcome == .succeeded(hasActiveBuilds: true))
        #expect(store.snapshot.runs.count == 3)
        #expect(store.snapshot.lastSuccessfulSync == now)
        #expect(store.lastError == nil)
        #expect(await cache.load() == store.snapshot)
    }

    @Test func theCacheIsShownBeforeAnyNetworkCall() async throws {
        let cache = BuildCacheStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/BuildCache.json"))
        let cached = BuildSnapshot(products: [CIProduct(id: "p", name: "Cached", productType: nil, appID: nil, appName: nil, bundleID: nil)], lastSuccessfulSync: now)
        try await cache.save(cached)
        let transport = MockTransport(reply: apiReply)
        let store = makeStore(cache: cache, transport: transport)

        await store.loadCacheIfNeeded()

        #expect(store.snapshot == cached)
        #expect(await transport.requests.isEmpty)
    }

    @Test func rateLimitsAreCountedAndKeepTheLastSnapshot() async {
        let transport = MockTransport { _ in MockTransport.Reply(status: 429) }
        let store = makeStore(transport: transport)

        #expect(await store.synchronize() == .rateLimited(consecutive: 1))
        #expect(await store.synchronize() == .rateLimited(consecutive: 2))
        #expect(store.lastError == .rateLimited)
        #expect(store.lastErrorMessage != nil)
        #expect(store.snapshot == .empty)
    }

    @Test func withoutAKeyNothingIsRequested() async {
        let transport = MockTransport(reply: apiReply)
        let store = makeStore(credentials: InMemoryCredentialsStore(), transport: transport)

        #expect(await store.synchronize() == .notConfigured)
        #expect(!store.isConfigured)
        #expect(await transport.requests.isEmpty)
    }

    @Test func twoSyncsNeverRunAtTheSameTime() async {
        let transport = MockTransport(reply: apiReply)
        let store = makeStore(transport: transport)

        async let first = store.synchronize()
        async let second = store.synchronize()
        _ = await (first, second)

        #expect(await requestCount(transport) { $0 == "/v1/ciProducts" } == 1)
    }

    @Test func removingTheKeyClearsTheSnapshotAndTheCache() async {
        let credentials = InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem))
        let cache = BuildCacheStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/BuildCache.json"))
        let store = makeStore(credentials: credentials, cache: cache, transport: MockTransport(reply: apiReply))
        await store.synchronize()

        try? await credentials.delete()
        await store.credentialsDidChange()
        store.stop()

        #expect(store.snapshot == .empty)
        #expect(await cache.load() == nil)
    }
}

struct SyncScheduleTests {
    @Test func refreshesOftenWhileABuildRunsAndRarelyOtherwise() {
        #expect(SyncSchedule.delay(after: .succeeded(hasActiveBuilds: true)) == .seconds(60))
        #expect(SyncSchedule.delay(after: .succeeded(hasActiveBuilds: false)) == .seconds(600))
    }

    @Test func rateLimitsBackOffUpToTwoHours() {
        #expect(SyncSchedule.delay(after: .rateLimited(consecutive: 1)) == .seconds(15 * 60))
        #expect(SyncSchedule.delay(after: .rateLimited(consecutive: 2)) == .seconds(30 * 60))
        #expect(SyncSchedule.delay(after: .rateLimited(consecutive: 3)) == .seconds(60 * 60))
        #expect(SyncSchedule.delay(after: .rateLimited(consecutive: 10)) == .seconds(2 * 3600))
    }
}


@MainActor
struct SyncPaceTests {
    private let busy = SyncOutcome.succeeded(hasActiveBuilds: true)
    private let calm = SyncOutcome.succeeded(hasActiveBuilds: false)

    @Test func theOpenWindowWatchesRunningBuildsClosely() {
        #expect(SyncSchedule.delay(after: busy, context: SyncContext(windowIsOpen: true)) == .seconds(30))
        #expect(SyncSchedule.delay(after: busy) == .seconds(60))
        #expect(SyncSchedule.delay(after: calm, context: SyncContext(windowIsOpen: true)) == .seconds(300))
        #expect(SyncSchedule.delay(after: calm) == .seconds(600))
    }

    @Test func aLockedScreenNeverGoesFasterThanTheSlowPace() {
        #expect(SyncSchedule.delay(after: busy, context: SyncContext(windowIsOpen: true, screenIsLocked: true)) == .seconds(600))
    }

    @Test func thePaceSlowsAsTheHourlyBudgetRunsDown() {
        func delay(_ remaining: Int) -> Duration {
            SyncSchedule.delay(after: busy, context: SyncContext(budget: RateLimit(limit: 3500, remaining: remaining)))
        }

        #expect(delay(3000) == .seconds(60))
        #expect(delay(1500) == .seconds(120))
        #expect(delay(700) == .seconds(240))
        #expect(delay(300) == .seconds(480))
        #expect(delay(40) == .seconds(1200))
    }

    @Test func aRateLimitStillBacksOffWhateverTheContext() {
        #expect(SyncSchedule.delay(after: .rateLimited(consecutive: 1), context: SyncContext(windowIsOpen: true)) == .seconds(900))
    }

    @Test func aSyncIsDueOnlyOnceItsDelayHasPassedAndFollowsTheContextAsItChanges() {
        let start = Date(timeIntervalSince1970: 1_791_000_000)

        #expect(!SyncSchedule.isDue(lastRun: start, now: start.addingTimeInterval(40), outcome: busy, context: SyncContext()))
        #expect(SyncSchedule.isDue(lastRun: start, now: start.addingTimeInterval(40), outcome: busy, context: SyncContext(windowIsOpen: true)))
        #expect(!SyncSchedule.isDue(lastRun: start, now: start.addingTimeInterval(200), outcome: busy, context: SyncContext(screenIsLocked: true)))
    }

    @Test func openingTheWindowAndLockingTheScreenAreRemembered() {
        let store = BuildStore()

        store.windowDidOpen()
        store.screenLockDidChange(isLocked: true)
        #expect(store.syncContext == SyncContext(windowIsOpen: true, screenIsLocked: true, budget: nil))

        store.windowDidClose()
        store.screenLockDidChange(isLocked: false)
        #expect(store.syncContext == SyncContext())
    }
}
