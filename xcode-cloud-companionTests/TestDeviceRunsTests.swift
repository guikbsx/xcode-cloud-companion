import Foundation
import Testing
@testable import XcodeCloudCompanion

struct TestDeviceRunsTests {
    @Test func perDeviceResultsFoldIntoOneEntryPerDevice() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciTestResults")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let devices = try await client.testDeviceRuns(buildActionID: "action-test")

        #expect(devices.map(\.deviceName) == ["Apple Watch Series 11", "iPhone 17", "iPhone 17 Pro Max"])
        let proMax = try #require(devices.last)
        #expect(proMax.osVersion == "27.0")
        #expect(proMax.testCount == 2)
        #expect(proMax.failedCount == 1)
        #expect(proMax.totalSeconds == 420.5)
        #expect(await transport.requests.first?.url?.path() == "/v1/ciBuildActions/action-test/testResults")
        #expect(await transport.requests.first?.queryValue("fields[ciTestResults]") == "status,destinationTestResults")
    }

    @Test func resultsSayWhetherEveryPageWasRead() async throws {
        let last = try Fixture.data("ciTestResults")
        var page = try #require(try JSONSerialization.jsonObject(with: last) as? [String: Any])
        page["links"] = [
            "self": "https://api.appstoreconnect.apple.com/v1/ciBuildActions/action-test/testResults",
            "next": "https://api.appstoreconnect.apple.com/v1/ciBuildActions/action-test/testResults?cursor=abc",
        ]
        let more = try JSONSerialization.data(withJSONObject: page)

        let whole = try await AppStoreConnectClient(credentials: .sample(), transport: MockTransport { request in
            MockTransport.Reply(body: request.url?.query()?.contains("cursor") == true ? last : more)
        }).testDeviceRuns(buildActionID: "action-test")
        #expect(whole.allSatisfy { $0.isComplete == true })
        #expect(whole.last?.testCount == 4, "two pages read")

        let transport = MockTransport { _ in MockTransport.Reply(body: more) }
        let cut = try await AppStoreConnectClient(credentials: .sample(), transport: transport).testDeviceRuns(buildActionID: "action-test")
        #expect(cut.allSatisfy { $0.isComplete == false })
        #expect(await transport.requests.count == AppStoreConnectClient.testResultPageLimit)
        #expect(AppStoreConnectClient.testResultPageLimit * 200 == 12_000)
    }

    @Test func resultsCutByTheOldLimitAreReadAgainButNeverTwice() throws {
        func devices(_ count: Int, complete: Bool?) -> [CITestDeviceRun] {
            [
                CITestDeviceRun(deviceName: "iPhone 16", osVersion: "27.2", testCount: count, totalSeconds: 55, isComplete: complete),
                CITestDeviceRun(deviceName: "iPhone SE", osVersion: "27.2", testCount: count, totalSeconds: 54, isComplete: complete),
            ]
        }
        let cached = BuildSnapshot(testDevicesByActionID: [
            "cut": devices(3000, complete: nil),
            "small": devices(2006, complete: nil),
            "readAgain": devices(3000, complete: true),
            "tooMany": devices(12_000, complete: false),
        ])

        let loaded = try JSONDecoder().decode(BuildSnapshot.self, from: JSONEncoder().encode(cached))

        #expect(loaded.testDevicesByActionID["cut"] == nil)
        #expect(Set(loaded.testDevicesByActionID.keys) == ["small", "readAgain", "tooMany"])
        let action = CIBuildAction(id: "cut", buildRunID: "r", name: "Test", actionType: .test, startedDate: nil, finishedDate: nil, executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true)
        #expect(loaded.needsTestResults(action))
    }

    @Test func workflowsCarryTheirTestDestinationCounts() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciWorkflows")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let workflows = try await client.workflows(productID: "product-1")

        #expect(workflows.map(\.id) == ["workflow-release", "workflow-pr"])
        #expect(workflows.map(\.name) == ["Release", "Pull Requests"])
        #expect(workflows.map(\.testDestinationCounts) == [[3], []])
    }

    @Test func machineMinutesBillEachDeviceForItsOwnTime() {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let test = CIBuildAction(id: "t", buildRunID: "r", name: "Test", actionType: .test, startedDate: start, finishedDate: start.addingTimeInterval(10 * 60), executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true)
        let archive = CIBuildAction(id: "a", buildRunID: "r", name: "Archive", actionType: .archive, startedDate: start, finishedDate: start.addingTimeInterval(8 * 60), executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true)
        let run = CIBuildRun(id: "r", productID: "p", number: 1, createdDate: start, startedDate: start, finishedDate: start.addingTimeInterval(10 * 60), executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil)
        var snapshot = BuildSnapshot(runs: [run], actionsByRunID: ["r": [test, archive]])

        #expect(UsageEstimator.machineSeconds(of: run, in: snapshot, now: start) == 18 * 60)

        snapshot.testDevicesByActionID["t"] = [
            CITestDeviceRun(deviceName: "A", osVersion: "27", testCount: 10, failedCount: 0, totalSeconds: 7 * 60),
            CITestDeviceRun(deviceName: "B", osVersion: "26", testCount: 10, failedCount: 0, totalSeconds: 7 * 60),
            CITestDeviceRun(deviceName: "C", osVersion: "27", testCount: 10, failedCount: 0, totalSeconds: 7 * 60),
        ]
        // Each device: 7 min of tests + 4.5 min of preparation; the archive keeps its wall clock (too few samples for a cap).
        #expect(UsageEstimator.machineSeconds(of: run, in: snapshot, now: start) == (3 * 11.5 + 8) * 60)
        let breakdown = UsageEstimator.testDeviceBreakdown(of: run, in: snapshot, now: start)
        #expect(breakdown == TestDeviceBreakdown(deviceCount: 3, deviceSeconds: 21 * 60, wallClockSeconds: 10 * 60, actionsWithoutResults: 0))
        let totals = UsageEstimator.totals(of: snapshot, in: DateInterval(start: start, duration: 60), now: start)
        #expect(totals.seconds(.machineMinutes) == (3 * 11.5 + 8) * 60)
        #expect(totals.seconds(.actionDuration) == 18 * 60)

        snapshot.testDevicesByActionID["t"]?[0].failedCount = 1
        #expect(UsageEstimator.machineSeconds(of: test, in: snapshot, now: start) == (14 + 4.5 + 2 * 11.5) * 60)

        snapshot.testDevicesByActionID["t"] = []
        #expect(UsageEstimator.machineSeconds(of: test, in: snapshot, now: start) == 10 * 60)
    }

    @Test func aSuccessfulArchiveIsBilledLikeItsShortestRunNotItsUpload() {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        func archive(_ number: Int, minutes: Double, status: CICompletionStatus = .succeeded) -> (CIBuildRun, CIBuildAction) {
            let created = start.addingTimeInterval(Double(number) * 3600)
            let run = CIBuildRun(id: "r\(number)", productID: "p", number: number, createdDate: created, startedDate: created, finishedDate: created.addingTimeInterval(minutes * 60), executionProgress: .complete, completionStatus: status, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil)
            let action = CIBuildAction(id: "a\(number)", buildRunID: run.id, name: "Archive", actionType: .archive, startedDate: created, finishedDate: created.addingTimeInterval(minutes * 60), executionProgress: .complete, completionStatus: status, isRequiredToPass: true)
            return (run, action)
        }
        let builds = [archive(1, minutes: 7.4), archive(2, minutes: 18.6), archive(3, minutes: 12.9), archive(4, minutes: 5.9, status: .failed)]
        let snapshot = BuildSnapshot(runs: builds.map(\.0), actionsByRunID: Dictionary(uniqueKeysWithValues: builds.map { ($0.0.id, [$0.1]) }))

        let model = MachineModel(snapshot: snapshot)

        #expect(model.seconds(of: builds[1].1, now: start) == 7.4 * 60)
        #expect(model.seconds(of: builds[0].1, now: start) == 7.4 * 60)
        #expect(model.seconds(of: builds[3].1, now: start) == 5.9 * 60)

        let tooFew = BuildSnapshot(runs: [builds[1].0], actionsByRunID: [builds[1].0.id: [builds[1].1]])
        #expect(MachineModel(snapshot: tooFew).seconds(of: builds[1].1, now: start) == 18.6 * 60)
    }

    @Test func oldCachesWithoutDeviceDataStillLoad() throws {
        let json = #"{"products": [], "runs": [], "actionsByRunID": {}, "lastSuccessfulSync": 0}"#
        let snapshot = try JSONDecoder().decode(BuildSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.testDevicesByActionID.isEmpty)
        #expect(snapshot.workflows.isEmpty)
        #expect(snapshot.lastSuccessfulSync == Date(timeIntervalSinceReferenceDate: 0))
    }
}
