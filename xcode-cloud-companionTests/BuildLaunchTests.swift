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

    @Test func openPullRequestsAreListedNewestFirstWithASafeAddress() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("scmPullRequests")) ?? Data(), headers: [:]) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let pullRequests = try await client.pullRequests(repositoryID: "repo-1")

        #expect(pullRequests.map(\.number) == [131, 128])
        #expect(pullRequests.map(\.label) == ["#131 Fix the CSV import", "#128 Add the cycle widget"])
        #expect(pullRequests.map(\.isCrossRepository) == [false, true])
        #expect(pullRequests[0].webURL == nil, "an http address is not opened")
        #expect(pullRequests[1].webURL?.host() == "github.com")
        #expect(pullRequests[1].sourceBranch == "feature/widget-cycle" && pullRequests[1].destinationBranch == "main")
    }

    @Test func theChoicesSplitBranchesFromTagsAndRememberWhichKindANameIs() {
        let references = [
            GitReference(id: "b1", name: "main", kind: .branch), GitReference(id: "t1", name: "v1.0", kind: .tag),
            GitReference(id: "b2", name: "release", kind: .branch), GitReference(id: "t2", name: "release", kind: .tag),
        ]

        let choices = LaunchChoices(references: references, pullRequests: nil)

        #expect(choices.branches.map(\.id) == ["b1", "b2"] && choices.tags.map(\.id) == ["t1", "t2"])
        #expect(choices.kind(of: "v1.0") == .tag)
        #expect(choices.kind(of: "release") == .branch, "a name both carry is taken as the branch")
        #expect(choices.kind(of: "unknown") == .branch && choices.kind(of: nil) == .branch)
    }

    @Test func aLongListIsNarrowedByTypingAndCapped() {
        let names = (1...100).map { "feature/\($0)" } + ["main"]

        let all = LaunchChoices.matching(names, query: "", name: { $0 })
        let some = LaunchChoices.matching(names, query: "  MAIN ", name: { $0 })
        let tens = LaunchChoices.matching(names, query: "feature/1", name: { $0 })

        #expect(all.shown.count == LaunchChoices.menuLimit && all.total == 101)
        #expect(some.shown == ["main"] && some.total == 1)
        #expect(tens.total == 12 && tens.shown.first == "feature/1")
    }

    @Test func theLastRunOnASourceComesFromTheCacheAndKeepsBranchesApartFromPullRequests() {
        func run(_ id: String, created: TimeInterval, branch: String?, pullRequest: Int? = nil) -> CIBuildRun {
            CIBuildRun(
                id: id, productID: "p", number: nil, createdDate: Date(timeIntervalSince1970: created), startedDate: nil, finishedDate: nil,
                executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: branch,
                isPullRequestBuild: pullRequest != nil, pullRequestNumber: pullRequest
            )
        }
        let runs = [
            run("old-main", created: 100, branch: "main"),
            run("new-main", created: 300, branch: "main"),
            run("pr-on-main", created: 400, branch: "main", pullRequest: 128),
            run("develop", created: 500, branch: "develop"),
        ]

        #expect(LaunchSourceHistory.lastRun(onBranchOrTag: "main", in: runs)?.id == "new-main")
        #expect(LaunchSourceHistory.lastRun(onPullRequest: 128, in: runs)?.id == "pr-on-main")
        #expect(LaunchSourceHistory.lastRun(onBranchOrTag: "v1.0", in: runs) == nil)
        #expect(LaunchSourceHistory.lastRun(onPullRequest: 7, in: runs) == nil)
    }

    @Test func theLauncherStillOffersBranchesWhenThePullRequestsCannotBeRead() async throws {
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/pullRequests") { return MockTransport.Reply(status: 500, body: Data(), headers: [:]) }
            if path.hasSuffix("/gitReferences") { return MockTransport.Reply(status: 200, body: (try? Fixture.data("scmGitReferences")) ?? Data(), headers: [:]) }
            return MockTransport.Reply(status: 200, body: Data(#"{"data":{"type":"scmRepositories","id":"repo-1","attributes":{"ownerName":"guik","repositoryName":"cumulus"}}}"#.utf8), headers: [:])
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let launcher = BuildLauncher(client: { client })

        let choices = try #require(await launcher.choices(for: "wf-1"))
        _ = await launcher.choices(for: "wf-1")

        #expect(choices.branches.map(\.name) == ["develop", "main"] && choices.tags.map(\.name) == ["v1.0"])
        #expect(choices.pullRequests == nil, "unread is not the same as none")
        #expect(await transport.requests.count == 3, "a second opening of the sheet asks nothing more")
    }

    // MARK: - Launcher

    private final class Log: Sendable {
        let posts = Mutex<Int>(0)
        let looks = Mutex<Int>(0)
        let pauses = Mutex<[Duration]>([])
    }

    /// What the build list answers at each look after a launch Apple did not confirm.
    private enum List: Sendable {
        /// The new run shows from this look on (1 is the first); before, the list is empty.
        case showsRun(fromLook: Int)
        case empty
        case fails(status: Int)
    }

    private func launcher(
        status: Int = 201, fixture: String? = "ciBuildRun-created", error: URLError? = nil, body: Data? = nil, list: List = .showsRun(fromLook: 1), log: Log
    ) -> BuildLauncher {
        let transport = MockTransport { request in
            if request.httpMethod == "POST" {
                log.posts.withLock { $0 += 1 }
                return MockTransport.Reply(status: status, body: body ?? (fixture.flatMap { try? Fixture.data($0) } ?? Data()), error: error, headers: [:])
            }
            let look = log.looks.withLock { count in
                count += 1
                return count
            }
            switch list {
            case .showsRun(let first) where look >= first:
                return MockTransport.Reply(status: 200, body: (try? Fixture.data("ciBuildRuns-latest")) ?? Data(), headers: [:])
            case .showsRun, .empty:
                return MockTransport.Reply(status: 200, body: Data(#"{"data":[]}"#.utf8), headers: [:])
            case .fails(let status):
                return MockTransport.Reply(status: status, body: Data(), headers: [:])
            }
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return BuildLauncher(client: { client }, now: { Date(timeIntervalSince1970: 1_791_581_400) }, pause: { duration in log.pauses.withLock { $0.append(duration) } })
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

    /// Seen on 2026-10-12: Apple answered 201, the app could not read the answer, and one look at the list, half a
    /// second later, did not show the build. The launch was announced as not confirmed while the build was running.
    @Test func anAnswerThatCannotBeReadInFullIsStillALaunch() async {
        let log = Log()
        let body = Data(#"{"data":{"type":"ciBuildRuns","id":"run-odd","attributes":{"number":"not a number","createdDate":12}}}"#.utf8)

        let outcome = await launcher(body: body, log: log).launch(request, productID: "p", workflowName: "Public archive")

        guard case .started(let run) = outcome else {
            Issue.record("expected a started run, got \(outcome)")
            return
        }
        #expect(run.id == "run-odd" && run.executionProgress == .pending && run.startReason == "MANUAL")
        #expect(run.workflowID == "wf-1" && run.workflowName == "Public archive" && run.productID == "p")
        #expect(run.createdDate != nil)
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == 0)
    }

    @Test func anAcceptedLaunchWithNothingReadableIsFoundInTheListAtALaterLook() async {
        let log = Log()

        let outcome = await launcher(body: Data("<html>".utf8), list: .showsRun(fromLook: 2), log: log).launch(request, productID: "p", workflowName: "Public archive")

        guard case .started(let run) = outcome else {
            Issue.record("expected a started run, got \(outcome)")
            return
        }
        #expect(run.id == "run-found")
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == 2)
        #expect(log.pauses.withLock { $0 } == [.seconds(2)])
    }

    @Test func anAcceptedLaunchTheListNeverShowsIsStillSaidToHaveStarted() async {
        for list in [List.empty, .fails(status: 503)] {
            let log = Log()

            let outcome = await launcher(body: Data("<html>".utf8), list: list, log: log).launch(request, productID: "p", workflowName: nil)

            #expect(outcome == .accepted)
            #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == BuildLauncher.lookDelays.count)
            #expect(LaunchSheet.message(for: outcome)?.contains("accepted") == true)
        }
    }

    @Test func anUnconfirmedLaunchIsLookedForMoreThanOnce() async {
        let log = Log()

        let outcome = await launcher(error: URLError(.timedOut), list: .showsRun(fromLook: 3), log: log).launch(request, productID: "p", workflowName: "Public archive")

        guard case .uncertain(let found?) = outcome else {
            Issue.record("expected an uncertain launch that found the new run, got \(outcome)")
            return
        }
        #expect(found.id == "run-found")
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == 3)
        #expect(log.pauses.withLock { $0 } == [.seconds(2), .seconds(4)])
    }

    @Test func aListReadSeveralTimesWithoutTheBuildSaysNothingSeemsToHaveStarted() async {
        let log = Log()

        let outcome = await launcher(error: URLError(.timedOut), list: .empty, log: log).launch(request, productID: "p", workflowName: nil)

        #expect(outcome == .uncertain(found: nil))
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == BuildLauncher.lookDelays.count)
    }

    @Test func aListThatCannotBeReadIsNotTakenForNoNewBuild() async {
        let log = Log()

        let outcome = await launcher(status: 503, body: Data(), list: .fails(status: 503), log: log).launch(request, productID: "p", workflowName: nil)

        #expect(outcome == .unknown)
        #expect(LaunchSheet.message(for: outcome)?.contains("may have started") == true)
        #expect(LaunchSheet.message(for: .uncertain(found: nil))?.contains("Nothing seems to have started") == true)
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == BuildLauncher.lookDelays.count)
    }

    @Test func aRateLimitOnTheListStopsTheLooks() async {
        let log = Log()

        let outcome = await launcher(error: URLError(.timedOut), list: .fails(status: 429), log: log).launch(request, productID: "p", workflowName: nil)

        #expect(outcome == .unknown)
        #expect(log.posts.withLock { $0 } == 1 && log.looks.withLock { $0 } == 1)
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
