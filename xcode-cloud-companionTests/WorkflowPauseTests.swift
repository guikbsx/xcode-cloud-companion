import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private func workflow(_ id: String = "wf-1", isEnabled: Bool? = true, isLocked: Bool? = false) -> CIWorkflow {
    var workflow = CIWorkflow(id: id, name: "Release", testDestinationCounts: [])
    workflow.productID = "p1"
    workflow.isEnabled = isEnabled
    workflow.isLockedForEditing = isLocked
    return workflow
}

private func answer(isEnabled: Bool?) -> Data {
    let attributes = isEnabled.map { #"{"name": "Release", "isEnabled": \#($0)}"# } ?? #"{"name": "Release"}"#
    return Data(#"{"data": {"type": "ciWorkflows", "id": "wf-1", "attributes": \#(attributes)}}"#.utf8)
}

@MainActor
struct WorkflowPauseTests {
    private final class Log: Sendable {
        let patches = Mutex<[URLRequest]>([])
        let reads = Mutex<Int>(0)
        let applied = Mutex<[String]>([])
    }

    /// `patch` answers the one write; `read` answers the read that follows an unconfirmed change.
    private func pauser(patch: MockTransport.Reply, read: MockTransport.Reply = MockTransport.Reply(body: answer(isEnabled: true)), log: Log) -> WorkflowPauser {
        let transport = MockTransport { request in
            if request.httpMethod == "PATCH" {
                log.patches.withLock { $0.append(request) }
                return patch
            }
            log.reads.withLock { $0 += 1 }
            return read
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return WorkflowPauser(client: { client }, applied: { id, isEnabled in log.applied.withLock { $0.append("\(id)=\(isEnabled)") } })
    }

    @Test func theRequestCarriesNothingButTheWorkflowAndItsNewState() throws {
        let request = WorkflowStateRequest(workflowID: "wf-1", isEnabled: false)

        let body = try #require(try JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        let data = try #require(body["data"] as? [String: Any])

        #expect(Set(body.keys) == ["data"])
        #expect(Set(data.keys) == ["type", "id", "attributes"])
        #expect(data["type"] as? String == "ciWorkflows" && data["id"] as? String == "wf-1")
        #expect(data["attributes"] as? [String: Bool] == ["isEnabled": false])
        #expect(AppStoreConnectEndpoint.updateWorkflow(id: "wf-1").path() == "/v1/ciWorkflows/wf-1")
        #expect(URLRequest(url: AppStoreConnectEndpoint.workflowState(id: "wf-1")).queryValue("fields[ciWorkflows]") == "isEnabled")
    }

    @Test(arguments: ["", "../x", "a b", "a/b", String(repeating: "a", count: 65)])
    func aMalformedIdentifierIsNeverSent(id: String) async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(body: answer(isEnabled: false)), log: log).setEnabled(false, workflow: workflow(id))

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(log.patches.withLock { $0.isEmpty })
        #expect(!WorkflowStateRequest(workflowID: id, isEnabled: false).isWellFormed)
    }

    @Test func pausingSendsOnePatchAndShowsApplesAnswer() async throws {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(body: answer(isEnabled: false)), log: log).setEnabled(false, workflow: workflow())

        #expect(outcome == .changed(isEnabled: false))
        #expect(outcome.message(wanted: false) == nil)
        #expect(log.applied.withLock { $0 } == ["wf-1=false"])
        let patch = try #require(log.patches.withLock { $0.first })
        #expect(log.patches.withLock { $0.count } == 1)
        #expect(patch.url?.path() == "/v1/ciWorkflows/wf-1")
        #expect(patch.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sentBody = try #require(patch.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: [String: Any]])
        #expect(sent["data"]?["attributes"] as? [String: Bool] == ["isEnabled": false])
        #expect(log.reads.withLock { $0 } == 0)
    }

    @Test func resumingWorksTheSameWay() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(body: answer(isEnabled: true)), log: log).setEnabled(true, workflow: workflow(isEnabled: false))

        #expect(outcome == .changed(isEnabled: true))
        #expect(log.applied.withLock { $0 } == ["wf-1=true"])
    }

    @Test func theStateShownIsApplesNotTheOneAskedFor() async {
        let log = Log()

        // Apple answers that the workflow is still enabled.
        let outcome = await pauser(patch: MockTransport.Reply(body: answer(isEnabled: true)), log: log).setEnabled(false, workflow: workflow())

        #expect(outcome == .changed(isEnabled: true))
        #expect(outcome.message(wanted: false) == "Apple reports this workflow as still enabled. Nothing changed; you can try again.")
        #expect(log.applied.withLock { $0 } == ["wf-1=true"])
    }

    @Test func anAnswerWithoutAStateIsReadNotAssumed() async {
        let log = Log()

        let outcome = await pauser(
            patch: MockTransport.Reply(body: answer(isEnabled: nil)), read: MockTransport.Reply(body: answer(isEnabled: false)), log: log
        ).setEnabled(false, workflow: workflow())

        #expect(outcome == .changed(isEnabled: false))
        #expect(log.reads.withLock { $0 } == 1)
        #expect(log.patches.withLock { $0.count } == 1)
    }

    @Test func aForbiddenKeyIsToldSoAndNothingChanges() async {
        let body = Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"x","detail":"no"}]}"#.utf8)
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(status: 403, body: body), log: log).setEnabled(false, workflow: workflow())

        guard case .notAllowed(let message) = outcome else {
            Issue.record("expected notAllowed, got \(outcome)")
            return
        }
        // The very words a refused launch gets.
        #expect(message == AppStoreConnectError.forbidden(code: "FORBIDDEN_ERROR", detail: "no").message)
        #expect(outcome.message(wanted: false) == message)
        #expect(log.applied.withLock { $0.isEmpty })
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0 } == 0)
    }

    @Test(arguments: [409, 422])
    func aRefusalShowsApplesWordsAndIsNotRetried(status: Int) async {
        let body = Data(#"{"errors":[{"status":"\#(status)","code":"ENTITY_ERROR","title":"Workflow is locked","detail":"Unlock it first."}]}"#.utf8)
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(status: status, body: body), log: log).setEnabled(false, workflow: workflow())

        #expect(outcome == .refused(message: "Workflow is locked Unlock it first."))
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0 } == 0)
        #expect(log.applied.withLock { $0.isEmpty })
    }

    @Test func aRateLimitChangesNothingAndIsNotRetried() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(status: 429), log: log).setEnabled(false, workflow: workflow())

        #expect(outcome == .rateLimited)
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0 } == 0)
    }

    @Test func aLockedWorkflowIsNeverSentAnything() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(body: answer(isEnabled: false)), log: log).setEnabled(false, workflow: workflow(isLocked: true))

        #expect(outcome == .failed(message: WorkflowPauser.lockedMessage))
        #expect(log.patches.withLock { $0.isEmpty } && log.reads.withLock { $0 } == 0)
    }

    @Test func aTimeoutIsFollowedByAReadNeverByASecondWrite() async {
        let log = Log()

        // The write timed out but did reach Apple: the read says the workflow is paused.
        let reached = await pauser(
            patch: MockTransport.Reply(error: URLError(.timedOut)), read: MockTransport.Reply(body: answer(isEnabled: false)), log: log
        ).setEnabled(false, workflow: workflow())

        #expect(reached == .uncertain(isEnabled: false))
        #expect(reached.message(wanted: false) == nil)
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0 } == 1)
        #expect(log.applied.withLock { $0 } == ["wf-1=false"])
    }

    @Test func anUnconfirmedChangeThatDidNotHappenSaysSo() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(status: 500), read: MockTransport.Reply(body: answer(isEnabled: true)), log: log)
            .setEnabled(false, workflow: workflow())

        #expect(outcome == .uncertain(isEnabled: true))
        #expect(outcome.message(wanted: false) == "Apple reports this workflow as still enabled. Nothing changed; you can try again.")
        #expect(log.patches.withLock { $0.count } == 1)
    }

    @Test func whenEvenTheReadFailsTheStateIsCalledUnknown() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(status: 500), read: MockTransport.Reply(status: 500), log: log).setEnabled(false, workflow: workflow())

        #expect(outcome == .uncertain(isEnabled: nil))
        #expect(outcome.message(wanted: false)?.contains("Check it in App Store Connect") == true)
        #expect(log.applied.withLock { $0.isEmpty })
        #expect(log.patches.withLock { $0.count } == 1)
    }

    @Test func aNetworkThatNeverLeftTheMacIsAPlainFailure() async {
        let log = Log()

        let outcome = await pauser(patch: MockTransport.Reply(error: URLError(.notConnectedToInternet)), log: log).setEnabled(false, workflow: workflow())

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(log.reads.withLock { $0 } == 0)
    }

    // MARK: - What shows the state

    @Test func theSidebarAndTheBuildListMarkAPausedWorkflow() {
        let run = CIBuildRun(
            id: "r1", productID: "p1", number: 1, createdDate: now, startedDate: now, finishedDate: now, executionProgress: .complete,
            completionStatus: .succeeded, startReason: nil, workflowID: "wf-1", workflowName: "Release", sourceBranchOrTag: nil
        )
        let product = CIProduct(id: "p1", name: "App", productType: "APP", appID: nil, appName: nil, bundleID: nil)
        func snapshot(_ workflow: CIWorkflow) -> BuildSnapshot { BuildSnapshot(products: [product], runs: [run], workflows: [workflow]) }

        let paused = SidebarContent(snapshot: snapshot(workflow(isEnabled: false, isLocked: true)), pinnedIDs: [], palette: AppPalette())
        #expect(paused.products.first?.workflows.first?.isPaused == true)
        #expect(paused.products.first?.workflows.first?.isLocked == true)
        #expect(BuildListModel(snapshot: snapshot(workflow(isEnabled: false)), scope: .workflow("wf-1"), now: now).isPausedWorkflow)

        for known in [workflow(isEnabled: true), workflow(isEnabled: nil)] {
            #expect(SidebarContent(snapshot: snapshot(known), pinnedIDs: [], palette: AppPalette()).products.first?.workflows.first?.isPaused == false)
            #expect(!BuildListModel(snapshot: snapshot(known), scope: .workflow("wf-1"), now: now).isPausedWorkflow)
        }
        #expect(!BuildListModel(snapshot: snapshot(workflow(isEnabled: false)), scope: .allBuilds, now: now).isPausedWorkflow)
    }

    @Test func theSyncAsksForTheEnabledAndLockedStates() {
        let fields = URLRequest(url: AppStoreConnectEndpoint.workflows(productID: "p1")).queryValue("fields[ciWorkflows]")

        #expect(fields == "name,actions,isEnabled,isLockedForEditing")
    }

    @Test func theSheetOfTheWorkflowAndItsCacheTakeApplesAnswer() async throws {
        let cache = WorkflowDetailsCache(directory: FileManager.default.temporaryDirectory.appending(path: "WorkflowDetails-\(UUID().uuidString)"))
        defer { Task { await cache.deleteAll() } }
        await cache.save(WorkflowDetailsFile(fetchedAt: now, workflows: [workflow(), workflow("wf-2")]), productID: "p1")
        let store = WorkflowDetailStore(cache: cache, client: { nil }, now: { now })
        await store.load(productID: "p1")

        await store.setEnabled(false, workflowID: "wf-1")

        #expect(store.workflow(id: "wf-1")?.isEnabled == false)
        #expect(store.workflow(id: "wf-2")?.isEnabled == true)
        let stored = try #require(await cache.load(productID: "p1"))
        #expect(stored.workflows.map(\.isEnabled) == [false, true])
        #expect(stored.fetchedAt == now)
    }

    @Test func aSyncAlreadyUnderWayDoesNotUndoAConfirmedPause() async throws {
        let clock = TestClock(now)
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if path == "/v1/ciProducts" { return MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data()) }
            if path.hasSuffix("/workflows") {
                // Apple's list, read by a sync, still says "enabled".
                return MockTransport.Reply(body: Data(#"{"data": [{"type": "ciWorkflows", "id": "wf-1", "attributes": {"name": "Release", "isEnabled": true}}], "links": {}}"#.utf8))
            }
            return MockTransport.Reply(body: Data(#"{"data": [], "links": {}}"#.utf8))
        }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let cache = BuildCacheStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/BuildCache.json"))
        let store = BuildStore(
            credentialsStore: InMemoryCredentialsStore(StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: pem)), cacheStore: cache,
            makeClient: { AppStoreConnectClient(credentials: $0, transport: transport) }, now: { clock.now }
        )
        await store.synchronize()
        #expect(store.snapshot.workflow(id: "wf-1")?.isEnabled == true)

        await store.setWorkflowEnabled(false, workflowID: "wf-1")
        #expect(store.snapshot.workflow(id: "wf-1")?.isEnabled == false)
        #expect(await cache.load()?.workflow(id: "wf-1")?.isEnabled == false)

        // A sync whose clock started before the confirmation keeps Apple's later answer.
        clock.advance(by: -30)
        await store.synchronize()
        #expect(store.snapshot.workflow(id: "wf-1")?.isEnabled == false)

        // A sync that starts afterwards reads the list for itself.
        clock.advance(by: 90)
        await store.synchronize()
        #expect(store.snapshot.workflow(id: "wf-1")?.isEnabled == true)
    }
}
