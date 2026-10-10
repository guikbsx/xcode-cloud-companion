import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildLaunchTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func relationships(_ request: BuildRunRequest) throws -> [String: Any] {
        let body = try json(request.body())
        let data = try #require(body["data"] as? [String: Any])
        return try #require(data["relationships"] as? [String: Any])
    }

    @Test func aLaunchNamesTheWorkflowAndExactlyOneSource() throws {
        let branch = try relationships(.launch(workflowID: "wf-1", source: .gitReference(id: "ref-main")))
        let pull = try relationships(.launch(workflowID: "wf-1", source: .pullRequest(id: "pr-7")))

        #expect(Set(branch.keys) == ["workflow", "sourceBranchOrTag"])
        #expect(Set(pull.keys) == ["workflow", "pullRequest"])
    }

    @Test func aRebuildNamesTheRunAndNoSource() throws {
        let rebuild = try relationships(.rebuild(buildRunID: "run-1", workflowID: "wf-1"))

        #expect(Set(rebuild.keys) == ["workflow", "buildRun"])
    }

    @Test func cleanIsSentOnlyWhenAskedFor() throws {
        func attributes(_ clean: Bool) throws -> Any? {
            let body = try json(BuildRunRequest.launch(workflowID: "wf", source: .gitReference(id: "r"), clean: clean).body())
            return (body["data"] as? [String: Any])?["attributes"]
        }

        #expect(try attributes(false) == nil)
        #expect((try attributes(true) as? [String: Bool]) == ["clean": true])
    }

    @Test(arguments: ["", "../x", "a b", "a/b", String(repeating: "a", count: 65)])
    func aMalformedIdentifierIsNeverSent(id: String) {
        #expect(!BuildRunRequest.launch(workflowID: id, source: .gitReference(id: "ok")).isWellFormed)
        #expect(!BuildRunRequest.launch(workflowID: "ok", source: .gitReference(id: id)).isWellFormed)
        #expect(!BuildRunRequest.rebuild(buildRunID: id, workflowID: "ok").isWellFormed)
        #expect(BuildRunRequest.launch(workflowID: "1f0c-22aa", source: .pullRequest(id: "9")).isWellFormed)
    }

    @Test func deletedReferencesAreLeftOutAndBranchesComeBeforeTags() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("scmGitReferences")) ?? Data(), headers: [:]) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let references = try await client.gitReferences(repositoryID: "repo-1")

        #expect(references.map(\.name) == ["develop", "main", "v1.0"])
        #expect(references.map(\.kind) == [.branch, .branch, .tag])
    }

    // MARK: - Launcher

    private final class Log: Sendable {
        let posts = Mutex<Int>(0)
    }

    private func launcher(status: Int = 201, fixture: String? = "ciBuildRun-created", error: URLError? = nil, body: Data? = nil, log: Log) -> BuildLauncher {
        let transport = MockTransport { request in
            if request.httpMethod == "POST" {
                log.posts.withLock { $0 += 1 }
                return MockTransport.Reply(status: status, body: body ?? (fixture.flatMap { try? Fixture.data($0) } ?? Data()), error: error, headers: [:])
            }
            return MockTransport.Reply(status: 200, body: (try? Fixture.data("ciBuildRuns-latest")) ?? Data(), headers: [:])
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return BuildLauncher(client: { client }, now: { Date(timeIntervalSince1970: 1_791_581_400) })
    }

    private let request = BuildRunRequest.launch(workflowID: "wf-1", source: .gitReference(id: "ref-main"))

    @Test func aStartedRunIsPendingAndKnowsItsWorkflow() async throws {
        let log = Log()

        let outcome = await launcher(log: log).launch(request, productID: "p", workflowName: "Public archive")

        guard case .started(let run) = outcome else {
            Issue.record("expected a started run, got \(outcome)")
            return
        }
        #expect(run.id == "run-new" && run.number == 391)
        #expect(run.executionProgress == .pending)
        #expect(run.workflowID == "wf-1" && run.workflowName == "Public archive" && run.productID == "p")
        #expect(log.posts.withLock { $0 } == 1)
    }

    @Test func aForbiddenKeyIsToldItMayNotLaunch() async {
        let body = Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"x","detail":"no"}]}"#.utf8)

        let outcome = await launcher(status: 403, body: body, log: Log()).launch(request, productID: "p", workflowName: nil)

        guard case .notAllowed = outcome else {
            Issue.record("expected notAllowed, got \(outcome)")
            return
        }
    }

    @Test(arguments: [409, 422])
    func aRefusalShowsApplesWordsAndPointsAtTheSource(status: Int) async {
        let body = Data(#"{"errors":[{"status":"\#(status)","code":"ENTITY_ERROR","title":"Workflow disabled","detail":"Enable it first.","source":{"pointer":"/data/relationships/sourceBranchOrTag"}}]}"#.utf8)
        let log = Log()

        let outcome = await launcher(status: status, body: body, log: log).launch(request, productID: "p", workflowName: nil)

        #expect(outcome == .refused(message: "Workflow disabled Enable it first.", pointsAtSource: true))
        #expect(log.posts.withLock { $0 } == 1)
    }

    @Test func aRateLimitMeansNothingStartedAndNothingIsRetried() async {
        let log = Log()

        let outcome = await launcher(status: 429, body: Data(), log: log).launch(request, productID: "p", workflowName: nil)

        #expect(outcome == .rateLimited)
        #expect(log.posts.withLock { $0 } == 1)
    }

    @Test func aTimeoutIsAmbiguousAndTheListIsReadBeforeAnyNewTry() async {
        let log = Log()

        let outcome = await launcher(error: URLError(.timedOut), log: log).launch(request, productID: "p", workflowName: "Public archive")

        guard case .uncertain(let found?) = outcome else {
            Issue.record("expected an uncertain launch that found the new run, got \(outcome)")
            return
        }
        #expect(found.id == "run-found" && found.workflowName == "Public archive")
        #expect(log.posts.withLock { $0 } == 1)
    }

    @Test func aServerErrorIsAmbiguousToo() async {
        let log = Log()

        let outcome = await launcher(status: 503, body: Data(), log: log).launch(request, productID: "p", workflowName: nil)

        if case .uncertain = outcome {} else { Issue.record("expected uncertain, got \(outcome)") }
        #expect(log.posts.withLock { $0 } == 1)
    }

    @Test func noConnectionMeansItNeverLeft() async {
        let outcome = await launcher(error: URLError(.notConnectedToInternet), log: Log()).launch(request, productID: "p", workflowName: nil)

        if case .failed = outcome {} else { Issue.record("expected a definite failure, got \(outcome)") }
    }

    @Test func anOldRunIsNotMistakenForTheNewOne() {
        let attempt = Date(timeIntervalSince1970: 1_791_581_400)
        func run(created: Date, reason: String?) -> CIBuildRun {
            CIBuildRun(
                id: "r", productID: "p", number: 1, createdDate: created, startedDate: nil, finishedDate: nil, executionProgress: .pending,
                completionStatus: nil, startReason: reason, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
            )
        }

        #expect(BuildLauncher.looksLikeOurs(run(created: attempt.addingTimeInterval(3), reason: "MANUAL"), since: attempt))
        #expect(!BuildLauncher.looksLikeOurs(run(created: attempt.addingTimeInterval(-3600), reason: "MANUAL"), since: attempt))
        #expect(!BuildLauncher.looksLikeOurs(run(created: attempt.addingTimeInterval(3), reason: "GIT_REF_CHANGE"), since: attempt))
    }

    @Test func aMalformedRequestNeverLeavesTheApp() async {
        let log = Log()

        let outcome = await launcher(log: log).launch(.launch(workflowID: "../x", source: .gitReference(id: "r")), productID: "p", workflowName: nil)

        if case .started = outcome { Issue.record("should not start") }
        #expect(log.posts.withLock { $0 } == 0)
    }

    @Test func aStartedRunShowsInTheListAtOnce() {
        let store = BuildStore()
        let run = CIBuildRun(
            id: "run-new", productID: "p", number: 391, createdDate: nil, startedDate: nil, finishedDate: nil, executionProgress: .pending,
            completionStatus: nil, startReason: "MANUAL", workflowID: "wf-1", workflowName: "Public archive", sourceBranchOrTag: nil
        )

        store.insertStarted(run)
        store.insertStarted(run)

        #expect(store.snapshot.runs.map(\.id) == ["run-new"])
    }
}
