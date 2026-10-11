import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildDetailTests {
    private let created = Date(timeIntervalSince1970: 1_791_000_000)

    private func run(
        progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .failed, reason: String? = "BRANCH_CHANGE",
        commit: CISourceCommit? = nil, counts: CIIssueCounts? = nil
    ) -> CIBuildRun {
        var run = CIBuildRun(
            id: "run-1", productID: "p", number: 389, createdDate: created, startedDate: created.addingTimeInterval(32),
            finishedDate: progress == .complete ? created.addingTimeInterval(32 + 372) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: reason, workflowID: "w", workflowName: "Public archive",
            sourceBranchOrTag: "develop"
        )
        run.sourceCommit = commit
        run.issueCounts = counts
        return run
    }

    private func action(_ id: String, _ type: CIActionType, name: String, offset: Double, length: Double, status: CICompletionStatus?, failures: Int? = nil) -> CIBuildAction {
        var action = CIBuildAction(
            id: id, buildRunID: "run-1", name: name, actionType: type, startedDate: created.addingTimeInterval(offset),
            finishedDate: status == .skipped ? nil : created.addingTimeInterval(offset + length), executionProgress: .complete,
            completionStatus: status, isRequiredToPass: true
        )
        action.issueCounts = failures.map { CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: $0, warnings: 0) }
        return action
    }

    private func model(
        _ run: CIBuildRun, workflow: CIWorkflow? = nil, actions: [CIBuildAction] = [], now: Date? = nil
    ) -> BuildDetailModel {
        let product = CIProduct(id: "p", name: "realmotivation", productType: "APP", appID: "123", appName: nil, bundleID: nil)
        return BuildDetailModel(run: run, product: product, workflow: workflow, actions: actions, teamID: "team-1", now: now ?? created.addingTimeInterval(1_000))
    }

    @Test func aRunningBuildsSheetIsRedrawnEverySecondAndAFinishedOneEveryMinute() {
        #expect(BuildDetailView.redrawInterval(for: run(progress: .running)) == 1)
        #expect(BuildDetailView.redrawInterval(for: run(progress: .pending)) == 1)
        #expect(BuildDetailView.redrawInterval(for: run()) == 60)
    }

    @Test func theHeaderNamesTheBuildItsStateAndItsReference() {
        let model = model(run())

        #expect(model.numberText == "#389")
        #expect(model.title == "realmotivation · Public archive")
        #expect(model.status == .failed)
        #expect(model.reference == "develop")
        #expect(model.appStoreConnectURL.absoluteString == "https://appstoreconnect.apple.com/teams/team-1/apps/123/ci/builds/run-1/summary")
    }

    @Test func aPullRequestBuildShowsThePullRequestInsteadOfTheBranch() {
        var pull = run()
        pull.isPullRequestBuild = true
        pull.pullRequestNumber = 7

        #expect(model(pull).reference == "PR #7")
    }

    @Test func theFriezeFollowsTheActionsInOrderWithTheirTimesAndFailures() {
        let actions = [
            action("t", .test, name: "Test - iOS", offset: 200, length: 200, status: .failed, failures: 3),
            action("a", .archive, name: "Archive - iOS", offset: 400, length: 0, status: .skipped),
            action("b", .build, name: "Build - iOS", offset: 40, length: 160, status: .succeeded),
        ]

        let frieze = model(run(), actions: actions).frieze

        #expect(frieze.map(\.id) == ["b", "t", "a"])
        #expect(frieze.map(\.status) == [.succeeded, .failed, .skipped])
        #expect(frieze[0].detail == "2 min, 40 sec")
        #expect(frieze[1].detail == "3 min, 20 sec · 3 failures")
        #expect(frieze[2].detail == "skipped")
    }

    @Test func factsAreTranslatedAndTimedAndTheOnesUnknownAreHidden() {
        var workflow = CIWorkflow(id: "w", name: "Public archive", testDestinationCounts: [])
        workflow.xcodeVersionName = "Xcode 27.1"

        let fields = model(run(), workflow: workflow).info

        #expect(fields.map(\.title) == ["Start condition", "Started", "Queued for", "Duration", "Xcode"])
        #expect(fields[0].value == "Branch change")
        #expect(fields[2].value == "32 sec")
        #expect(fields[3].value == "6 min, 12 sec")
        #expect(fields[4].help?.contains("Current workflow configuration") == true)
        #expect(model(run(reason: nil)).info.contains { $0.title == "Start condition" } == false)
    }

    @Test func aRunningBuildShowsElapsedTimeInsteadOfDuration() {
        let model = model(run(progress: .running), now: created.addingTimeInterval(32 + 125))

        #expect(model.info.last?.title == "Elapsed")
        #expect(model.info.last?.value == "2 min, 5 sec")
    }

    @Test func theCommitIsHiddenWithoutShaAndItsLinkMustBeHTTPS() {
        #expect(model(run()).commit == nil)
        #expect(model(run(commit: CISourceCommit(commitSha: nil, message: "x", authorName: nil, webURL: nil))).commit == nil)

        let sha = "d4c3b2a1f0e9d8c7b6a5"
        let safe = model(run(commit: CISourceCommit(commitSha: sha, message: " Fix\n", authorName: "Guik", webURL: URL(string: "https://github.com/a/b/commit/1")))).commit
        let unsafe = model(run(commit: CISourceCommit(commitSha: sha, message: nil, authorName: "", webURL: URL(string: "file:///etc/passwd")))).commit

        #expect(safe?.shortSha == "d4c3b2a1" && safe?.message == "Fix" && safe?.webURL != nil)
        #expect(unsafe?.webURL == nil && unsafe?.author == nil)
    }

    @Test func unknownCountersStayUnknownNotZero() {
        #expect(model(run()).issueCount == nil)
        #expect(model(run(counts: CIIssueCounts(analyzerWarnings: 0, errors: 1, testFailures: 3, warnings: 2))).issueCount == 6)
    }

    // MARK: - Extras

    private func store(directory: URL, transport: MockTransport) -> BuildExtrasStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return BuildExtrasStore(cache: BuildExtrasCache(directory: directory), client: { client })
    }

    private func transport() -> MockTransport {
        MockTransport { _ in
            MockTransport.Reply(status: 200, body: (try? Fixture.data("ciBuilds-sample")) ?? Data(), headers: [:])
        }
    }

    @Test func aFinishedBuildsTestFlightBuildsAreAskedForOnceAndThenReadFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()
        let finished = run()

        let first = store(directory: directory, transport: transport)
        await first.loadBetaBuilds(for: finished)
        await first.loadBetaBuilds(for: finished)
        let second = store(directory: directory, transport: transport)
        await second.loadBetaBuilds(for: finished)

        #expect(await transport.requests.count == 1)
        #expect(second.extras(for: "run-1")?.betaBuilds?.first?.version == "390")
    }

    @Test func aRunningBuildIsAskedForEachTimeAndNeverWrittenToDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()
        let running = run(progress: .running)

        let store = store(directory: directory, transport: transport)
        await store.loadBetaBuilds(for: running)
        await store.loadBetaBuilds(for: running)

        #expect(await transport.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aRunIdentifierCannotEscapeTheCacheFolder() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BuildExtrasCache(directory: directory)

        await cache.save(BuildExtras(betaBuilds: []), runID: "../escape")

        #expect(await cache.load(runID: "../escape") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
