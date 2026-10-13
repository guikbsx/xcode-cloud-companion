import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private func workflow(_ id: String = "wf-1", locked: Bool? = false) -> CIWorkflow {
    var workflow = CIWorkflow(id: id, name: "Release", testDestinationCounts: [])
    workflow.productID = "p1"
    workflow.description = "Ships to TestFlight"
    workflow.clean = false
    workflow.isEnabled = true
    workflow.isLockedForEditing = locked
    workflow.xcodeVersionID = "xc-26-4"
    workflow.xcodeVersionName = "Xcode 26.4"
    workflow.xcodeVersion = "26.4"
    workflow.macOSVersionID = "mac-26"
    workflow.macOSVersionName = "macOS 26"
    workflow.repositoryName = "guik/cumulus"
    return workflow
}

/// Apple's answer to a change: the attributes it holds now, the versions as relationships only.
private func answer(name: String, xcodeVersionID: String = "xc-27-1") -> Data {
    Data(#"""
    {"data": {"type": "ciWorkflows", "id": "wf-1",
      "attributes": {"name": "\#(name)", "description": "Ships to TestFlight", "clean": true, "isEnabled": true},
      "relationships": {"xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": "\#(xcodeVersionID)"}}, "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": "mac-27-1"}}}}}
    """#.utf8)
}

@MainActor
struct WorkflowEditTests {
    private final class Log: Sendable {
        let patches = Mutex<[URLRequest]>([])
        let reads = Mutex<[String]>([])
        let applied = Mutex<[String]>([])
    }

    private func editor(patch: MockTransport.Reply, read: MockTransport.Reply = MockTransport.Reply(body: answer(name: "Read back")), log: Log) -> WorkflowEditor {
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if request.httpMethod == "PATCH" {
                log.patches.withLock { $0.append(request) }
                return patch
            }
            if path == "/v1/ciXcodeVersions" { return MockTransport.Reply(body: (try? Fixture.data("ciXcodeVersions")) ?? Data()) }
            if path.hasSuffix("/macOsVersions") { return MockTransport.Reply(body: (try? Fixture.data("ciMacOsVersions")) ?? Data()) }
            log.reads.withLock { $0.append(path) }
            return read
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return WorkflowEditor(client: { client }, budget: { nil }, applied: { workflow in log.applied.withLock { $0.append(workflow.name) } })
    }

    @Test func theRequestCarriesOnlyWhatChanged() throws {
        let unchanged = WorkflowUpdateRequest.changes(from: workflow(), name: " Release ", description: "Ships to TestFlight", clean: false, xcodeVersionID: "xc-26-4", macOSVersionID: "mac-26")
        let renamed = WorkflowUpdateRequest.changes(from: workflow(), name: "Release 2", description: "Ships to TestFlight", clean: true, xcodeVersionID: "xc-27-1", macOSVersionID: "mac-26")

        #expect(unchanged.isEmpty && !unchanged.isWellFormed)
        #expect(renamed == WorkflowUpdateRequest(workflowID: "wf-1", name: "Release 2", description: nil, clean: true, xcodeVersionID: "xc-27-1", macOSVersionID: nil))

        let body = try #require(try JSONSerialization.jsonObject(with: renamed.body()) as? [String: Any])
        let data = try #require(body["data"] as? [String: Any])
        #expect(Set(data.keys) == ["type", "id", "attributes", "relationships"])
        #expect((data["attributes"] as? [String: Any])?.keys.sorted() == ["clean", "name"])
        let relationships = try #require(data["relationships"] as? [String: Any])
        #expect(Set(relationships.keys) == ["xcodeVersion"])
        #expect(((relationships["xcodeVersion"] as? [String: Any])?["data"] as? [String: String]) == ["type": "ciXcodeVersions", "id": "xc-27-1"])
    }

    @Test(arguments: ["", "../x", "a b", String(repeating: "a", count: 65)])
    func aMalformedIdentifierOrAnEmptyNameIsNeverSent(id: String) async {
        #expect(!WorkflowUpdateRequest(workflowID: id, name: "x").isWellFormed)
        #expect(!WorkflowUpdateRequest(workflowID: "wf-1", xcodeVersionID: id).isWellFormed)
        #expect(!WorkflowUpdateRequest(workflowID: "wf-1", name: "   ").isWellFormed)
        let log = Log()
        let outcome = await editor(patch: MockTransport.Reply(body: answer(name: "x")), log: log).save(WorkflowUpdateRequest(workflowID: id, name: "x"), workflow: workflow())
        if case .failed = outcome {} else { Issue.record("expected a failure, got \(outcome)") }
        #expect(log.patches.withLock { $0.isEmpty })
    }

    @Test func aSavedChangeShowsApplesAnswerWithTheVersionsNamed() async throws {
        let log = Log()
        let editor = editor(patch: MockTransport.Reply(body: answer(name: "Release 2")), log: log)
        await editor.loadVersions(currentXcodeVersionID: "xc-26-4")

        let outcome = await editor.save(WorkflowUpdateRequest(workflowID: "wf-1", name: "Release 2", xcodeVersionID: "xc-27-1"), workflow: workflow())

        guard case .saved(let saved) = outcome else {
            Issue.record("expected a saved workflow, got \(outcome)")
            return
        }
        #expect(saved.name == "Release 2" && saved.clean == true, "the attributes are Apple's")
        #expect(saved.xcodeVersionID == "xc-27-1" && saved.xcodeVersionName == "Xcode 27.1" && saved.xcodeVersion == "27.1")
        #expect(saved.macOSVersionName == "macOS Tahoe 27.1" && saved.repositoryName == "guik/cumulus", "what the answer does not carry is kept")
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0.isEmpty })
        #expect(log.applied.withLock { $0 } == ["Release 2"])
        #expect(outcome.message == nil)
    }

    @Test func aForbiddenKeyIsToldAndNothingIsRead() async {
        let log = Log()
        let body = Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"x","detail":"no"}]}"#.utf8)

        let outcome = await editor(patch: MockTransport.Reply(status: 403, body: body), log: log).save(WorkflowUpdateRequest(workflowID: "wf-1", name: "x"), workflow: workflow())

        if case .notAllowed = outcome {} else { Issue.record("expected notAllowed, got \(outcome)") }
        #expect(log.reads.withLock { $0.isEmpty } && log.applied.withLock { $0.isEmpty })
    }

    @Test func anUnconfirmedChangeIsReadBackNeverSentAgain() async {
        let log = Log()

        let outcome = await editor(patch: MockTransport.Reply(error: URLError(.timedOut)), log: log).save(WorkflowUpdateRequest(workflowID: "wf-1", name: "x"), workflow: workflow())

        guard case .uncertain(let read?) = outcome else {
            Issue.record("expected an uncertain outcome with the workflow read back, got \(outcome)")
            return
        }
        #expect(read.name == "Read back")
        #expect(log.patches.withLock { $0.count } == 1 && log.reads.withLock { $0 } == ["/v1/ciWorkflows/wf-1"])
        #expect(log.applied.withLock { $0 } == ["Read back"])
        #expect(outcome.message?.contains("did not confirm") == true)
    }

    @Test func aLockedWorkflowIsNotSent() async {
        let log = Log()

        let outcome = await editor(patch: MockTransport.Reply(body: answer(name: "x")), log: log).save(WorkflowUpdateRequest(workflowID: "wf-1", name: "x"), workflow: workflow(locked: true))

        #expect(outcome == .failed(message: WorkflowEditor.lockedMessage))
        #expect(log.patches.withLock { $0.isEmpty })
    }

    @Test func theVersionsAreReadOncePerSessionNewestPublicFirst() async throws {
        let log = Log()
        let editor = editor(patch: MockTransport.Reply(body: Data()), log: log)

        await editor.loadVersions(currentXcodeVersionID: "xc-26-4")
        await editor.loadVersions(currentXcodeVersionID: "xc-26-4")

        let versions = try #require(editor.xcodeVersions)
        #expect(WorkflowEditor.ordered(versions).map(\.name) == ["Xcode 27.1", "Xcode 27.2 beta 2", "Xcode 27.1.1 Release Candidate", "Xcode 27.0", "Xcode 26.4"])
        #expect(editor.macOSVersionsByXcode["xc-26-4"]?.map(\.name) == ["macOS Tahoe 27.1", "macOS Tahoe 27.0"])
        #expect(WorkflowEditSheet.label(versions[1], latest: true) == "Xcode 27.1 (latest)")
    }

    @Test func adoptingAnAnswerKeepsWhatItDoesNotCarry() {
        var answer = CIWorkflow(id: "wf-1", name: "Release 2", testDestinationCounts: [])
        answer.clean = true
        answer.xcodeVersionID = "xc-27-1"
        var kept = workflow()

        kept.adopt(answer)

        #expect(kept.name == "Release 2" && kept.clean == true && kept.xcodeVersionID == "xc-27-1")
        #expect(kept.description == nil, "the answer's description is Apple's, even when empty")
        #expect(kept.repositoryName == "guik/cumulus" && kept.isEnabled == true && kept.macOSVersionName == "macOS 26", "untouched when the answer says nothing")
    }

    @Test func withoutProNothingIsSentNorRead() async {
        let asked = Mutex<Int>(0)
        let transport = MockTransport { _ in
            asked.withLock { $0 += 1 }
            return MockTransport.Reply(body: answer(name: "x"))
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let editor = WorkflowEditor(client: { client }, budget: { nil }, applied: { _ in }, allowed: { false })

        await editor.loadVersions(currentXcodeVersionID: "xc-27-1")
        await editor.loadMacOSVersions(xcodeVersionID: "xc-27-1")
        let outcome = await editor.save(WorkflowUpdateRequest(workflowID: "wf-1", name: "x"), workflow: workflow())

        guard case .failed(let message) = outcome else {
            Issue.record("a locked edit must fail, got \(outcome)")
            return
        }
        #expect(message == ProFeatureText.required)
        #expect(asked.withLock { $0 } == 0)
        #expect(editor.xcodeVersions == nil)
    }
}
