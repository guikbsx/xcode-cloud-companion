import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ResultsTabsTests {
    private let created = Date(timeIntervalSince1970: 1_791_000_000)

    private func action(_ id: String, _ type: CIActionType, name: String, counts: CIIssueCounts? = nil) -> CIBuildAction {
        var action = CIBuildAction(
            id: id, buildRunID: "run-1", name: name, actionType: type, startedDate: created, finishedDate: created.addingTimeInterval(60),
            executionProgress: .complete, completionStatus: .failed, isRequiredToPass: true
        )
        action.issueCounts = counts
        return action
    }

    private func results(_ fixture: String = "ciTests-sample", action: String = "action-1") async throws -> [String: [CITestResult]] {
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data(fixture)) ?? Data(), headers: [:]) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return [action: try await client.testResults(buildActionID: action)]
    }

    @Test func testsAreGroupedByClassWithFailuresFirst() async throws {
        let model = TestsTabModel(results: try await results(), actions: [action("action-1", .test, name: "Test - iOS")])

        #expect(model.total == 3)
        #expect(model.failed == 2)
        #expect(model.groups.first?.failedCount ?? 0 > 0)
        #expect(model.groups.flatMap(\.rows).map(\.status).contains(.mixed))
        #expect(model.groups.flatMap(\.rows).map(\.status).contains(.expectedFailure))
    }

    @Test func statusAndDestinationFiltersNarrowTheList() async throws {
        let results = try await results()
        let actions = [action("action-1", .test, name: "Test - iOS")]

        let failed = TestsTabModel(results: results, actions: actions, status: .failed)
        let passed = TestsTabModel(results: results, actions: actions, status: .passed)
        let ipad = TestsTabModel(results: results, actions: actions, destination: "iPad Pro 13")
        let none = TestsTabModel(results: results, actions: actions, actionID: "other")

        #expect(failed.total == 2 && failed.groups.flatMap(\.rows).allSatisfy { $0.status.isFailure })
        #expect(passed.total == 0)
        #expect(ipad.total > 0 && ipad.groups.flatMap(\.rows).flatMap(\.devices).allSatisfy { $0.deviceName == "iPad Pro 13" })
        #expect(none.total == 0)
        #expect(failed.destinations == ["iPad Pro 13", "iPhone 17 Pro"])
    }

    @Test func aRowKeepsItsMessageLocationAndDevices() async throws {
        let model = TestsTabModel(results: try await results(), actions: [action("action-1", .test, name: "Test - iOS")])

        let first = try #require(model.groups.flatMap(\.rows).first { $0.message == "XCTAssertEqual failed" })
        #expect(first.location == "SyncTests.swift:18" || first.location?.hasSuffix(":18") == true)
        #expect(first.devices.count == 2)
    }

    @Test func issuesAreGroupedByActionAndSortedBySeverity() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("ciIssues-sample")) ?? Data(), headers: [:]) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let issues = ["action-1": try await client.issues(buildActionID: "action-1")]

        let model = IssuesTabModel(issues: issues, actions: [action("action-1", .build, name: "Build - iOS"), action("action-2", .test, name: "Test - iOS")])

        #expect(model.groups.map(\.actionName) == ["Build - iOS"])
        #expect(model.groups[0].rows.map(\.type) == [.error, .testFailure, .unknown("SOMETHING_NEW")])
        #expect(model.groups[0].rows[0].location == "Sync.swift:42")
        #expect(model.total == 3)
    }

    @Test func theResultsSurviveTheDiskRoundTrip() async throws {
        let original = BuildExtras(testsByAction: try await results(), testsComplete: true)

        let decoded = try JSONDecoder().decode(BuildExtras.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.schemaVersion == BuildExtras.currentVersion)
    }

    // MARK: - Loading

    private func run(finished: Bool = true) -> CIBuildRun {
        CIBuildRun(
            id: "run-1", productID: "p", number: 1, createdDate: created, startedDate: created, finishedDate: finished ? created : nil,
            executionProgress: finished ? .complete : .running, completionStatus: finished ? .failed : nil, startReason: nil,
            workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func store(_ directory: URL, _ transport: MockTransport) -> BuildExtrasStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return BuildExtrasStore(cache: BuildExtrasCache(directory: directory), client: { client })
    }

    @Test func aFinishedBuildsTestsAreAskedForOnceThenReadFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "results-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("ciTests-sample")) ?? Data(), headers: [:]) }
        let actions = [action("action-1", .test, name: "Test - iOS"), action("action-2", .build, name: "Build - iOS")]

        let first = store(directory, transport)
        await first.loadTests(for: run(), actions: actions)
        let second = store(directory, transport)
        await second.loadTests(for: run(), actions: actions)

        #expect(await transport.requests.count == 1)
        #expect(first.state(.tests, runID: "run-1") == .loaded && second.state(.tests, runID: "run-1") == .loaded)
        #expect(second.extras(for: "run-1")?.testsByAction["action-1"]?.count == 3)
    }

    @Test func aFailureKeepsWhatWasReadAndTheRetryOnlyAsksForTheRest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "results-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = Mutex(true)
        let transport = MockTransport { request in
            if request.url?.path().contains("action-2") == true, failing.withLock({ $0 }) {
                return MockTransport.Reply(status: 500, body: Data(), headers: [:])
            }
            return MockTransport.Reply(status: 200, body: (try? Fixture.data("ciTests-sample")) ?? Data(), headers: [:])
        }
        let actions = [action("action-1", .test, name: "Test A"), action("action-2", .test, name: "Test B")]
        let store = store(directory, transport)

        await store.loadTests(for: run(), actions: actions)
        guard case .failed(_, let done, let total) = store.state(.tests, runID: "run-1") else {
            Issue.record("expected a failure")
            return
        }
        #expect((done, total) == (1, 2))
        #expect(store.extras(for: "run-1")?.testsByAction["action-1"] != nil)

        failing.withLock { $0 = false }
        let before = await transport.requests.count
        await store.loadTests(for: run(), actions: actions)

        #expect(store.state(.tests, runID: "run-1") == .loaded)
        #expect(await transport.requests.count - before == 1)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aRunningBuildsResultsAreNeverWrittenToDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "results-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("ciIssues-sample")) ?? Data(), headers: [:]) }

        let store = store(directory, transport)
        await store.loadIssues(for: run(finished: false), actions: [action("action-1", .build, name: "Build")])

        #expect(store.state(.issues, runID: "run-1") == .loaded)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func anActionKnownToHaveNoIssueIsNotAskedFor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "results-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("ciIssues-sample")) ?? Data(), headers: [:]) }
        let clean = CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 0, warnings: 0)

        let store = store(directory, transport)
        await store.loadIssues(for: run(), actions: [action("action-1", .build, name: "Build", counts: clean)])

        #expect(await transport.requests.isEmpty)
    }
}
