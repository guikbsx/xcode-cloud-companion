import Foundation
import Testing
@testable import XcodeCloudCompanion

/// XCO-198: a build sheet reads past 3 000 test cases, says when it still stops short, and reads again what the old limit cut.
struct TestResultLimitTests {
    private func results(_ count: Int, action: String) -> [CITestResult] {
        (0..<count).map { CITestResult(id: "\(action)-\($0)", buildActionID: action, className: "Suite", name: "test\($0)", status: .success, message: nil, file: nil, devices: []) }
    }

    @Test func listsCutByTheOldLimitAreDroppedToBeReadAgain() {
        var old = BuildExtras(testsByAction: ["cut": results(3000, action: "cut"), "small": results(12, action: "small")], testsComplete: true)

        let reloaded = old.droppingTestsCutAtLegacyLimit()
        #expect(reloaded.testsByAction["cut"] == nil)
        #expect(reloaded.testsByAction["small"]?.count == 12)
        #expect(!reloaded.testsComplete, "the sheet asks for the missing action")

        old.testPageLimit = AppStoreConnectClient.testResultPageLimit
        #expect(old.droppingTestsCutAtLegacyLimit() == old, "read with the new limit: exactly 3 000 is a real count")
    }

    @Test func theCacheDropsThemOnLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = BuildExtrasCache(directory: folder)
        await cache.save(BuildExtras(testsByAction: ["cut": results(3000, action: "cut")], testsComplete: true), runID: "run-1")

        let loaded = try #require(await cache.load(runID: "run-1"))

        #expect(loaded.testsByAction.isEmpty && !loaded.testsComplete)
    }

    @MainActor @Test func theSheetReadsSixtyPagesAndRemembersAnActionItCouldNotFinish() async throws {
        let last = try Fixture.data("ciTests-sample")
        var page = try #require(try JSONSerialization.jsonObject(with: last) as? [String: Any])
        page["links"] = ["next": "https://api.appstoreconnect.apple.com/v1/ciBuildActions/action-1/testResults?cursor=abc"]
        let more = try JSONSerialization.data(withJSONObject: page)
        let transport = MockTransport { _ in MockTransport.Reply(body: more) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let list = try await client.testResultList(buildActionID: "action-1")
        #expect(!list.isComplete)
        #expect(await transport.requests.count == AppStoreConnectClient.testResultPageLimit)

        let whole = try await AppStoreConnectClient(credentials: .sample(), transport: MockTransport { _ in MockTransport.Reply(body: last) })
            .testResultList(buildActionID: "action-1")
        #expect(whole.isComplete && whole.results.count == 3)

        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let run = CIBuildRun(id: "run-1", productID: "p", number: 1, createdDate: start, startedDate: start, finishedDate: start, executionProgress: .complete, completionStatus: .failed, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil)
        let action = CIBuildAction(id: "action-1", buildRunID: "run-1", name: "Tests", actionType: .test, startedDate: start, finishedDate: start, executionProgress: .complete, completionStatus: .failed, isRequiredToPass: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BuildExtrasStore(cache: BuildExtrasCache(directory: folder), client: { client })

        await store.loadTests(for: run, actions: [action])

        let extras = try #require(store.extras(for: "run-1"))
        #expect(extras.testsCut == ["action-1"])
        #expect(extras.testPageLimit == AppStoreConnectClient.testResultPageLimit)
        #expect(await BuildExtrasCache(directory: folder).load(runID: "run-1")?.testsCut == ["action-1"])
    }
}
