import Foundation
import Testing
@testable import XcodeCloudCompanion

/// Answers like the app would, and remembers what it was asked.
actor FakeIPCService: IPCService {
    var refreshResult = IPCResult(lastSuccessfulSync: CLIFixture.date("2026-10-10T10:00:30Z"), accepted: true, outcome: "succeeded")
    var refreshDelay: Duration = .zero
    var detailsLoader: @Sendable (String) async -> Bool = { _ in false }
    private(set) var refreshWaits: [Bool] = []
    private(set) var refreshAccounts: [String?] = []
    private(set) var openedBuilds: [String] = []
    private(set) var detailRequests: [String] = []
    var launchResult = IPCResult(launched: true, buildRunID: "run-new", buildNumber: 46)
    private(set) var launches: [IPCLaunchRequest] = []

    func set(launchResult: IPCResult) {
        self.launchResult = launchResult
    }

    func launch(_ request: IPCLaunchRequest) async -> IPCResult {
        launches.append(request)
        return launchResult
    }

    func set(refreshResult: IPCResult, delay: Duration = .zero) {
        self.refreshResult = refreshResult
        refreshDelay = delay
    }

    func set(detailsLoader: @escaping @Sendable (String) async -> Bool) {
        self.detailsLoader = detailsLoader
    }

    func ping(accountID: String?) async -> IPCResult {
        IPCResult(appVersion: "1.0", lastSuccessfulSync: CLIFixture.date("2026-10-10T09:55:00Z"), isSyncing: false, hasCredentials: true)
    }

    func refresh(wait: Bool, accountID: String?) async -> IPCResult {
        refreshWaits.append(wait)
        refreshAccounts.append(accountID)
        try? await Task.sleep(for: refreshDelay)
        return refreshResult
    }

    func open(buildRunID: String) async -> IPCResult {
        openedBuilds.append(buildRunID)
        return IPCResult(opened: true)
    }

    func loadDetails(buildRunID: String) async -> IPCResult {
        detailRequests.append(buildRunID)
        return IPCResult(loaded: await detailsLoader(buildRunID))
    }
}

@MainActor
final class FakeSync: RefreshableSync {
    var lastSuccessfulSync: Date?
    var isSyncing = false
    var credentials = true
    var outcome = SyncOutcome.succeeded(hasActiveBuilds: false)
    var syncedAt = CLIFixture.now
    private(set) var synchronizeCount = 0

    func hasCredentials() async -> Bool { credentials }

    func synchronize() async -> SyncOutcome {
        synchronizeCount += 1
        lastSuccessfulSync = syncedAt
        return outcome
    }
}

enum IPCTestSocket {
    /// A short path: a socket address holds 103 bytes, and the test host's temporary folder is already long.
    static func path() -> String {
        FileManager.default.temporaryDirectory.appending(path: "c-\(UUID().uuidString.prefix(8)).sock").path(percentEncoded: false)
    }

    static func server(_ service: any IPCService, path: String = path()) async throws -> (IPCSocketServer, String) {
        let dispatcher = IPCDispatcher(service: service)
        let server = IPCSocketServer(path: path) { await dispatcher.reply(to: $0) }
        try await server.start()
        return (server, path)
    }
}

struct IPCProtocolTests {
    private func response(_ json: String, service: FakeIPCService = FakeIPCService()) async -> IPCResponse {
        await IPCDispatcher(service: service).response(to: Data(json.utf8))
    }

    @Test func framesAreOneJSONObjectWithISODates() throws {
        let request = IPCRequest(id: "7", method: "refresh", params: IPCRequest.Params(wait: true))
        #expect(String(decoding: IPCCodec.encode(request), as: UTF8.self) == #"{"id":"7","method":"refresh","params":{"wait":true}}"#)
        #expect(IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)) == request)

        let response = IPCResponse(id: "7", result: IPCResult(lastSuccessfulSync: CLIFixture.date("2026-10-10T09:55:00Z"), accepted: true))
        #expect(String(decoding: IPCCodec.encode(response), as: UTF8.self) == #"{"id":"7","result":{"accepted":true,"lastSuccessfulSync":"2026-10-10T09:55:00Z"}}"#)
        #expect(IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)) == response)
    }

    @Test func everyMethodReachesTheService() async {
        let service = FakeIPCService()

        let ping = await response(#"{"id":"1","method":"ping"}"#, service: service)
        #expect(ping.id == "1" && ping.result?.appVersion == "1.0" && ping.result?.hasCredentials == true && ping.error == nil)

        let refresh = await response(#"{"id":"2","method":"refresh","params":{"wait":true}}"#, service: service)
        #expect(refresh.result?.accepted == true && refresh.result?.outcome == "succeeded")
        _ = await response(#"{"id":"3","method":"refresh"}"#, service: service)
        #expect(await service.refreshWaits == [true, false])

        let open = await response(#"{"id":"4","method":"open","params":{"buildRunID":"run-a44"}}"#, service: service)
        #expect(open.result?.opened == true)
        #expect(await service.openedBuilds == ["run-a44"])

        let details = await response(#"{"id":"5","method":"loadDetails","params":{"buildRunID":"run-a44"}}"#, service: service)
        #expect(details.result?.loaded == false)
        #expect(await service.detailRequests == ["run-a44"])
    }

    @Test func whatIsNotUnderstoodIsRefusedByName() async {
        #expect(await response(#"{"id":"1","method":"cancel"}"#).error == IPCFailure(code: "METHOD_NOT_FOUND", message: "Unknown method 'cancel'."))
        #expect(await response(#"{"id":"1","method":"launch"}"#).id == "1")
        #expect(await response("not json").error?.code == "PARSE_ERROR")
        #expect(await response(#"{"method":"ping"}"#).error?.code == "PARSE_ERROR")
        #expect(await response(#"{"id":"1","method":"open"}"#).error?.code == "INVALID_PARAMS")
        #expect(await response(#"{"id":"1","method":"open","params":{"buildRunID":"../../etc"}}"#).error?.code == "INVALID_PARAMS")
    }
}

@MainActor
struct AppIPCServiceTests {
    private let now = CLIFixture.now

    private func service(_ sync: FakeSync) -> AppIPCService {
        AppIPCService(sync: { _ in sync }, appVersion: "1.0", now: { CLIFixture.now })
    }

    @Test func pingDescribesTheApp() async {
        let sync = FakeSync()
        sync.lastSuccessfulSync = now.addingTimeInterval(-300)

        #expect(await service(sync).ping(accountID: nil) == IPCResult(appVersion: "1.0", lastSuccessfulSync: now.addingTimeInterval(-300), isSyncing: false, hasCredentials: true))
    }

    @Test func aStaleCacheIsRefreshedAndWaitedFor() async {
        let sync = FakeSync()
        sync.lastSuccessfulSync = now.addingTimeInterval(-300)

        let result = await service(sync).refresh(wait: true, accountID: nil)

        #expect(result == IPCResult(lastSuccessfulSync: now, accepted: true, outcome: "succeeded"))
        #expect(sync.synchronizeCount == 1)
    }

    @Test func withoutWaitingTheSyncStartsAndTheAnswerLeavesAtOnce() async throws {
        let sync = FakeSync()

        let result = await service(sync).refresh(wait: false, accountID: nil)

        #expect(result.accepted == true && result.outcome == nil)
        for _ in 0..<50 where sync.synchronizeCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sync.synchronizeCount == 1)
    }

    @Test func aSyncThirtySecondsOldIsNotAskedAgain() async {
        let sync = FakeSync()
        sync.lastSuccessfulSync = now.addingTimeInterval(-29)

        #expect(await service(sync).refresh(wait: true, accountID: nil) == IPCResult(lastSuccessfulSync: now.addingTimeInterval(-29), accepted: false, reason: "recent"))
        #expect(sync.synchronizeCount == 0)

        sync.lastSuccessfulSync = now.addingTimeInterval(-31)
        #expect(await service(sync).refresh(wait: true, accountID: nil).accepted == true)
    }

    @Test func aRunningSyncIsReportedAndWaitingSeesItsEnd() async {
        let sync = FakeSync()
        sync.isSyncing = true
        sync.lastSuccessfulSync = now.addingTimeInterval(-300)

        #expect(await service(sync).refresh(wait: false, accountID: nil) == IPCResult(lastSuccessfulSync: now.addingTimeInterval(-300), accepted: false, reason: "syncing"))

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            sync.lastSuccessfulSync = now
            sync.isSyncing = false
        }
        #expect(await service(sync).refresh(wait: true, accountID: nil) == IPCResult(lastSuccessfulSync: now, accepted: false, reason: "syncing"))
        #expect(sync.synchronizeCount == 0)
    }

    @Test func withoutAKeyNothingIsAsked() async {
        let sync = FakeSync()
        sync.credentials = false

        #expect(await service(sync).refresh(wait: true, accountID: nil) == IPCResult(accepted: false, reason: "noCredentials"))
        #expect(sync.synchronizeCount == 0)
    }

    @Test func eachAccountIsAskedThroughItsOwnSync() async {
        let personal = FakeSync()
        personal.lastSuccessfulSync = now.addingTimeInterval(-300)
        let work = FakeSync()
        work.lastSuccessfulSync = now.addingTimeInterval(-600)
        let service = AppIPCService(
            sync: { id in id == nil ? personal : ["work": work][id ?? ""] }, appVersion: "1.0", now: { CLIFixture.now }
        )

        #expect(await service.ping(accountID: "work").lastSuccessfulSync == now.addingTimeInterval(-600))
        #expect(await service.refresh(wait: true, accountID: "work").accepted == true)
        #expect(work.synchronizeCount == 1 && personal.synchronizeCount == 0)

        // An account removed in the app since the command listed them.
        #expect(await service.refresh(wait: true, accountID: "gone") == IPCResult(accepted: false, reason: "unknownAccount"))
        #expect(await service.ping(accountID: "gone").hasCredentials == false)

        // No account at all: the app has no key to sync with.
        let empty = AppIPCService(sync: { _ in nil }, appVersion: "1.0", now: { CLIFixture.now })
        #expect(await empty.refresh(wait: true, accountID: nil) == IPCResult(accepted: false, reason: "noCredentials"))
    }

    @Test func outcomesHaveAStableName() {
        #expect(SyncOutcome.succeeded(hasActiveBuilds: true).ipcName == "succeeded")
        #expect(SyncOutcome.rateLimited(consecutive: 2).ipcName == "rateLimited")
        #expect(SyncOutcome.failed.ipcName == "failed")
        #expect(SyncOutcome.notConfigured.ipcName == "notConfigured")
    }

    @Test func openAndDetailsGoThroughTheApp() async {
        var service = service(FakeSync())
        let opened = FakeSync()
        service.openBuild = { _ in opened.isSyncing = true }
        service.loadBuildDetails = { $0 == "run-a44" }

        #expect(await service.open(buildRunID: "run-a44") == IPCResult(opened: true))
        #expect(opened.isSyncing)
        #expect(await service.loadDetails(buildRunID: "run-a44") == IPCResult(loaded: true))
        #expect(await service.loadDetails(buildRunID: "run-b9") == IPCResult(loaded: false))
    }
}

struct IPCSocketTests {
    @Test func theSocketLivesAtTheGroupContainerRoot() {
        let group = URL(filePath: "/Users/me/Library/Group Containers/4HYT2U85R2.com.guik.cumulus/")

        #expect(SharedContainer.socketPath(groupContainer: group, applicationSupport: group.appending(path: "Library/Application Support/"))
            == "/Users/me/Library/Group Containers/4HYT2U85R2.com.guik.cumulus/ipc.sock")
        #expect(SharedContainer.socketPath(groupContainer: group, applicationSupport: URL(filePath: "/Users/me/Library/Application Support/")) == nil)
        #expect(SharedContainer.socketPath(groupContainer: nil, applicationSupport: URL(filePath: "/tmp/")) == nil)
    }

    @Test func aPathLongerThanASocketAddressIsRefused() throws {
        let suffix = "/Library/Group Containers/4HYT2U85R2.com.guik.cumulus/ipc.sock"
        let fits = "/Users/" + String(repeating: "u", count: 103 - 7 - suffix.utf8.count) + suffix
        #expect(fits.utf8.count == 103)
        _ = try IPCSocket.address(path: fits)

        #expect(throws: IPCSocketError.pathTooLong) { try IPCSocket.address(path: fits + "x") }
    }

    @Test func aRequestCrossesTheSocketAndComesBack() async throws {
        let service = FakeIPCService()
        let (server, path) = try await IPCTestSocket.server(service)
        let client = IPCClient(path: path)

        #expect(await client.ping()?.appVersion == "1.0")
        let result = try await client.send(IPCRequest(id: "r1", method: "refresh", params: IPCRequest.Params(wait: true)), timeout: 5)
        #expect(result.accepted == true && result.lastSuccessfulSync == CLIFixture.date("2026-10-10T10:00:30Z"))
        #expect(await service.refreshWaits == [true])

        await server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.ping() == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func oneConnectionCarriesSeveralRequestsAndBadLinesGetAnAnswer() async throws {
        let (server, path) = try await IPCTestSocket.server(FakeIPCService())
        let descriptor = try IPCSocket.makeSocket()
        defer { close(descriptor) }
        #expect(try IPCSocket.connect(descriptor, to: path))
        IPCSocket.setTimeout(5, on: descriptor, option: SO_RCVTIMEO)
        var buffer = Data()

        #expect(IPCSocket.writeLine(Data(#"{"id":"1","method":"ping"}"#.utf8), to: descriptor))
        let first = try #require(IPCSocket.readLine(from: descriptor, buffer: &buffer))
        #expect(IPCCodec.decode(IPCResponse.self, from: first)?.id == "1")

        #expect(IPCSocket.writeLine(Data("garbage".utf8), to: descriptor))
        let second = try #require(IPCSocket.readLine(from: descriptor, buffer: &buffer))
        #expect(IPCCodec.decode(IPCResponse.self, from: second)?.error?.code == "PARSE_ERROR")

        #expect(IPCSocket.writeLine(Data(#"{"id":"3","method":"nope"}"#.utf8), to: descriptor))
        let third = try #require(IPCSocket.readLine(from: descriptor, buffer: &buffer))
        #expect(IPCCodec.decode(IPCResponse.self, from: third)?.error?.code == "METHOD_NOT_FOUND")
        await server.stop()
    }

    @Test func aLineOverSixtyFourKilobytesClosesTheConnection() async throws {
        let (server, path) = try await IPCTestSocket.server(FakeIPCService())
        let descriptor = try IPCSocket.makeSocket()
        defer { close(descriptor) }
        #expect(try IPCSocket.connect(descriptor, to: path))
        IPCSocket.setTimeout(5, on: descriptor, option: SO_RCVTIMEO)

        let flood = Data(repeating: 0x61, count: 80 * 1024)
        _ = flood.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var buffer = Data()
        #expect(IPCSocket.readLine(from: descriptor, buffer: &buffer) == nil)
        #expect(await IPCClient(path: path).ping() != nil)
        await server.stop()
    }

    @Test func severalClientsAreServedAtOnce() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(accepted: true), delay: .milliseconds(300))
        let (server, path) = try await IPCTestSocket.server(service)
        let client = IPCClient(path: path)
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await withTaskGroup(of: Bool.self) { group in
                for index in 0..<6 {
                    group.addTask {
                        (try? await client.send(IPCRequest(id: "\(index)", method: "refresh"), timeout: 5))?.accepted == true
                    }
                }
                for await answered in group {
                    #expect(answered)
                }
            }
        }

        // Six waits of 300 ms one after the other would take 1.8 s.
        #expect(elapsed < .milliseconds(1_200))
        await server.stop()
    }

    @Test func aSocketLeftByACrashIsReplaced() async throws {
        let path = IPCTestSocket.path()
        let orphan = try IPCSocket.makeSocket()
        try IPCSocket.bind(orphan, to: path)
        close(orphan)
        #expect(FileManager.default.fileExists(atPath: path))

        let (server, _) = try await IPCTestSocket.server(FakeIPCService(), path: path)

        #expect(await IPCClient(path: path).ping() != nil)
        await server.stop()
    }

    @Test func aSecondInstanceLeavesTheFirstOnesSocketAlone() async throws {
        let (first, path) = try await IPCTestSocket.server(FakeIPCService())
        let second = IPCSocketServer(path: path) { _ in Data("{}".utf8) }

        await #expect(throws: IPCSocketError.alreadyServing) { try await second.start() }
        #expect(await !second.isListening)
        #expect(await IPCClient(path: path).ping()?.appVersion == "1.0")
        await first.stop()
    }

    @Test func aSilentServerTimesOutAndAMissingOneIsUnreachable() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(accepted: true), delay: .seconds(2))
        let (server, path) = try await IPCTestSocket.server(service)

        await #expect(throws: IPCSocketError.timedOut) {
            try await IPCClient(path: path).send(IPCRequest(id: "1", method: "refresh"), timeout: 0.3)
        }
        await #expect(throws: IPCSocketError.unreachable) {
            try await IPCClient(path: IPCTestSocket.path()).send(IPCRequest(id: "1", method: "ping"), timeout: 0.3)
        }
        await server.stop()
    }
}

struct CLIRefreshTests {
    private func json(_ result: CLIResult) throws -> [String: Any] {
        try CLIFixture.json(result).data as? [String: Any] ?? [:]
    }

    @Test func refreshAsksTheAppAndWaitingBringsTheStatus() async throws {
        let service = FakeIPCService()
        let (server, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        let quick = await CumulusCLI.run(arguments: ["refresh"], environment: environment)
        #expect(quick.exitCode == 0)
        #expect(Set(try json(quick).keys) == ["accepted", "appLaunched", "outcome", "waited"])
        #expect(try CLIFixture.json(quick).meta["lastSuccessfulSync"] as? String == "2026-10-10T10:00:30Z")
        #expect(try CLIFixture.json(quick).meta["appRunning"] as? Bool == true)

        let waited = await CumulusCLI.run(arguments: ["refresh", "--wait", "--timeout", "5"], environment: environment)
        let data = try json(waited)
        #expect(data["accepted"] as? Bool == true && data["outcome"] as? String == "succeeded" && data["waited"] as? Bool == true)
        #expect((data["status"] as? [String: Any])?["runningBuilds"] as? Int == 2)
        #expect(await service.refreshWaits == [false, true])
        await server.stop()
    }

    @Test func refreshAsksForTheAccountOnScreenOrForTheOneNamed() async throws {
        let service = FakeIPCService()
        let (server, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environmentWithTwoAccounts()
        environment.socketPath = path

        let shown = await CumulusCLI.run(arguments: ["refresh"], environment: environment)
        let named = await CumulusCLI.run(arguments: ["refresh", "--account", "Work"], environment: environment)

        #expect(await service.refreshAccounts == [AccountRegistry.firstAccountID, "work-1"])
        #expect(try CLIFixture.json(shown).meta["account"] as? String == "Personal")
        #expect(try CLIFixture.json(named).meta["account"] as? String == "Work")
        #expect(await CumulusCLI.run(arguments: ["refresh", "--account", "Client"], environment: environment).exitCode == 5)

        // An account removed in the app since the command read the list.
        await service.set(refreshResult: IPCResult(accepted: false, reason: IPCRefreshReason.unknownAccount))
        let gone = await CumulusCLI.run(arguments: ["refresh", "--account", "Work", "--json"], environment: environment)
        #expect(gone.exitCode == 5 && gone.stderr.contains("NOT_FOUND"))
        await server.stop()
    }

    @Test func anAccountIdThatIsNotOneIsRefusedBeforeItReachesTheApp() async {
        let service = FakeIPCService()
        let reply = await IPCDispatcher(service: service).response(to: Data(#"{"id":"1","method":"refresh","params":{"accountID":"../x"}}"#.utf8))

        #expect(reply.error?.code == IPCFailure.invalidParams)
        #expect(await service.refreshWaits.isEmpty)
    }

    @Test func aRecentSyncIsNotAFailure() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(lastSuccessfulSync: CLIFixture.now, accepted: false, reason: "recent"))
        let (server, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment(isTerminal: true)
        environment.socketPath = path

        let result = await CumulusCLI.run(arguments: ["refresh"], environment: environment)

        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("Cumulus synced less than 30 seconds ago: nothing to refresh.\n"))
        await server.stop()
    }

    @Test func anAppThatIsNotRunningIsStartedFirst() async throws {
        let path = IPCTestSocket.path()
        let service = FakeIPCService()
        let dispatcher = IPCDispatcher(service: service)
        let server = IPCSocketServer(path: path) { await dispatcher.reply(to: $0) }
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        environment.launchApp = { (try? await server.start()) != nil }

        let result = await CumulusCLI.run(arguments: ["refresh"], environment: environment)

        #expect(result.exitCode == 0)
        #expect(try json(result)["appLaunched"] as? Bool == true)
        await server.stop()
    }

    @Test func anAppThatCannotBeReachedIsExitCodeFour() async throws {
        var environment = try await CLIFixture.environment()
        environment.socketPath = IPCTestSocket.path()
        environment.launchPatience = 0.6

        let refused = await CumulusCLI.run(arguments: ["refresh"], environment: environment)
        #expect(refused.exitCode == 4 && refused.stderr.contains("APP_UNREACHABLE"))

        environment.launchApp = { true }
        let neverAnswers = await CumulusCLI.run(arguments: ["refresh"], environment: environment)
        #expect(neverAnswers.exitCode == 4)

        environment.socketPath = nil
        #expect(await CumulusCLI.run(arguments: ["refresh"], environment: environment).exitCode == 4)
    }

    @Test func aSyncLongerThanTheTimeoutIsExitCodeSix() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(accepted: true), delay: .seconds(2))
        let (server, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        let result = await CumulusCLI.run(arguments: ["refresh", "--wait", "--timeout", "0.3"], environment: environment)

        #expect(result.exitCode == 6 && result.stderr.contains("TIMEOUT"))
        await server.stop()
    }

    @Test func anAppWithoutAKeySaysToAddOne() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(accepted: false, reason: "noCredentials"))
        let (server, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        let result = await CumulusCLI.run(arguments: ["refresh"], environment: environment)

        #expect(result.exitCode == 3 && result.stderr.contains("API key"))
        await server.stop()
    }

    @Test func everyAnswerSaysWhetherTheAppIsRunning() async throws {
        let (server, path) = try await IPCTestSocket.server(FakeIPCService())
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        #expect(try CLIFixture.json(await CumulusCLI.run(arguments: ["apps"], environment: environment)).meta["appRunning"] as? Bool == true)
        await server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try CLIFixture.json(await CumulusCLI.run(arguments: ["apps"], environment: environment)).meta["appRunning"] as? Bool == false)
    }

    @Test func aBuildNobodyOpenedHasItsDetailsFetchedByTheApp() async throws {
        let service = FakeIPCService()
        var environment = try await CLIFixture.environment()
        let directory = CLIFixture.directory(in: environment)
        await service.set(detailsLoader: { runID in
            await BuildExtrasCache(directory: directory.appending(path: "BuildDetails")).save(BuildExtras(issuesComplete: true, testsComplete: true, artifactsComplete: true), runID: runID)
            return true
        })
        let (server, path) = try await IPCTestSocket.server(service)
        environment.socketPath = path

        let cached = try json(await CumulusCLI.run(arguments: ["build", "Beta#10", "--cached"], environment: environment))
        #expect(cached["detailsAvailable"] as? Bool == false)
        #expect(await service.detailRequests.isEmpty)

        let fetched = try json(await CumulusCLI.run(arguments: ["build", "Beta#10"], environment: environment))
        #expect(fetched["detailsAvailable"] as? Bool == true && fetched["hint"] == nil)
        #expect(await service.detailRequests == ["run-b10"])

        // Already complete, or still running: the app is not asked.
        _ = await CumulusCLI.run(arguments: ["build", "Alpha#44"], environment: environment)
        _ = await CumulusCLI.run(arguments: ["build", "Alpha#45"], environment: environment)
        #expect(await service.detailRequests == ["run-b10"])
        await server.stop()
    }
}
