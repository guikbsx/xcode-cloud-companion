import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ReferencesTests {
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    private func run(
        _ id: String, number: Int, minutesAgo: Double, branch: String?, pullRequest: (Int, String?)? = nil,
        status: CICompletionStatus? = .succeeded, progress: CIExecutionProgress = .complete, workflow: String = "Release"
    ) -> CIBuildRun {
        let created = now.addingTimeInterval(-minutesAgo * 60)
        return CIBuildRun(
            id: id, productID: "p", number: number, createdDate: created, startedDate: created.addingTimeInterval(30), finishedDate: progress == .complete ? now : nil,
            executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: "w", workflowName: workflow,
            sourceBranchOrTag: branch, isPullRequestBuild: pullRequest != nil, pullRequestNumber: pullRequest?.0, pullRequestTitle: pullRequest?.1
        )
    }

    private func snapshot(_ runs: [CIBuildRun]) -> BuildSnapshot {
        BuildSnapshot(products: [CIProduct(id: "p", name: "Cumulus", productType: "APP", appID: "1", appName: nil, bundleID: nil)], runs: runs, workflows: [])
    }

    private let pullRequest128 = PullRequestReference(
        id: "pr-128", number: 128, title: "Add the cycle widget", sourceBranch: "feature/widget-cycle", destinationBranch: "main",
        isCrossRepository: false, webURL: URL(string: "https://github.com/guik/cumulus/pull/128")
    )

    @Test func eachReferenceShowsItsNewestBuildNewestReferenceFirst() {
        let runs = [
            run("old-main", number: 390, minutesAgo: 600, branch: "main"),
            run("new-main", number: 394, minutesAgo: 5, branch: "main", status: nil, progress: .running),
            run("develop", number: 392, minutesAgo: 60, branch: "develop", status: .failed),
            run("pr", number: 393, minutesAgo: 30, branch: "feature/widget-cycle", pullRequest: (128, "Add the cycle widget")),
            run("nameless", number: 1, minutesAgo: 1, branch: nil),
        ]

        let model = ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil)

        #expect(model.rows.map(\.title) == ["main", "#128 Add the cycle widget", "develop"])
        #expect(model.rows.map(\.lastRun.id) == ["new-main", "pr", "develop"])
        #expect(model.rows.map(\.status) == [.running, .succeeded, .failed])
        #expect(model.rows[0].runningSince != nil && model.rows[1].runningSince == nil)
        #expect(model.rows[0].detail == "Running · Cumulus · Release · #394")
        #expect(model.rows[0].age(now: now) == "5m")
        #expect(!model.hasNothing)
    }

    @Test func theRowsAreGroupedByDayAndSearchedLikeTheBuildList() {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let runs = [
            run("today", number: 3, minutesAgo: 10, branch: "main"),
            run("old", number: 1, minutesAgo: 60 * 24 * 20, branch: "develop"),
            run("pr", number: 2, minutesAgo: 30, branch: "feature/x", pullRequest: (128, "Add the cycle widget")),
        ]

        let model = ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil, now: now, calendar: paris, locale: Locale(identifier: "en_US"))
        let searched = ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil, query: "cycle", now: now, calendar: paris)

        #expect(model.groups.map(\.title) == ["Today", "September 2026"])
        #expect(model.groups[0].rows.map(\.title) == ["main", "#128 Add the cycle widget"])
        #expect(searched.rows.map(\.key) == [.pullRequest(128)] && !searched.hasNothing)
        #expect(ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil, query: "nothing", now: now).rows.isEmpty)
    }

    @Test func aPullRequestsBuildCountsForThePullRequestNotForItsBranch() {
        let runs = [run("pr", number: 2, minutesAgo: 1, branch: "feature/x", pullRequest: (7, nil))]

        let model = ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil)

        #expect(model.rows.map(\.key) == [.pullRequest(7)])
        #expect(model.rows[0].title == "#7", "no title from the host: the number alone")
        #expect(ReferencesModel.key(of: runs[0]) == .pullRequest(7))
    }

    @Test func applesListClosesPullRequestsAndNamesTheirBranches() {
        let runs = [
            run("open", number: 2, minutesAgo: 1, branch: "feature/widget-cycle", pullRequest: (128, "cached title")),
            run("closed", number: 3, minutesAgo: 2, branch: "fix/old", pullRequest: (120, "Old fix")),
            run("main", number: 4, minutesAgo: 3, branch: "main"),
        ]

        let known = ReferencesModel(snapshot: snapshot(runs), openPullRequests: [pullRequest128])
        let unknown = ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil)

        #expect(known.rows.map(\.title) == ["#128 Add the cycle widget", "main"])
        #expect(known.rows[0].subtitle == "feature/widget-cycle into main")
        #expect(known.rows[0].webURL?.path() == "/guik/cumulus/pull/128")
        #expect(unknown.rows.map(\.title) == ["#128 cached title", "#120 Old fix", "main"])
    }

    @Test func theFilterKeepsOneKind() {
        let runs = [
            run("pr", number: 2, minutesAgo: 1, branch: "feature/x", pullRequest: (7, "x")),
            run("main", number: 4, minutesAgo: 3, branch: "main"),
        ]

        #expect(ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil, filter: .pullRequests).rows.map(\.key) == [.pullRequest(7)])
        #expect(ReferencesModel(snapshot: snapshot(runs), openPullRequests: nil, filter: .branches).rows.map(\.key) == [.branchOrTag("main")])
        #expect(ReferencesModel(snapshot: snapshot([]), openPullRequests: nil).hasNothing)
    }

    @Test func theBuildListScopesToOneReference() {
        let runs = [
            run("pr", number: 2, minutesAgo: 1, branch: "main", pullRequest: (7, "x")),
            run("main", number: 4, minutesAgo: 3, branch: "main"),
        ]

        let branch = BuildListModel(snapshot: snapshot(runs), scope: .reference(.branchOrTag("main")), now: now)
        let pullRequest = BuildListModel(snapshot: snapshot(runs), scope: .reference(.pullRequest(7)), now: now)

        #expect(branch.rows.map(\.id) == ["main"] && branch.title == "main")
        #expect(pullRequest.rows.map(\.id) == ["pr"] && pullRequest.title == "PR #7")
        #expect(BuildListScope(.references) == .allBuilds && BuildListScope(.workflow("w")) == .workflow("w"))
    }

    // MARK: - Store

    private func store(pullRequestsStatus: Int = 200) -> (ReferencesStore, MockTransport) {
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/pullRequests") {
                return MockTransport.Reply(status: pullRequestsStatus, body: (try? Fixture.data("scmPullRequests")) ?? Data(), headers: [:])
            }
            return MockTransport.Reply(status: 200, body: Data(#"{"data":{"type":"scmRepositories","id":"repo-1","attributes":{"ownerName":"guik","repositoryName":"cumulus"}}}"#.utf8), headers: [:])
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return (ReferencesStore(client: { client }, budget: { nil }), transport)
    }

    @Test func theStoreReadsOpenPullRequestsOncePerRepositoryAndNotAgainWithinFiveMinutes() async throws {
        let (store, transport) = store()
        let runs = [
            run("pr", number: 2, minutesAgo: 1, branch: "a", pullRequest: (128, nil)),
            run("pr2", number: 3, minutesAgo: 2, branch: "b", pullRequest: (131, nil)),
        ]

        await store.load(snapshot: snapshot(runs), now: now)
        await store.load(snapshot: snapshot(runs), now: now.addingTimeInterval(60))

        #expect(store.openPullRequests?.map(\.number) == [131, 128])
        #expect(!store.loadFailed)
        #expect(await transport.requests.count == 2, "one repository lookup, one list; nothing a minute later")

        await store.load(snapshot: snapshot(runs), now: now.addingTimeInterval(ReferencesStore.freshness + 1))
        #expect(await transport.requests.count == 3, "the repository is remembered, only the list is read again")
    }

    @Test func withoutPullRequestBuildsTheStoreAsksNothing() async throws {
        let (store, transport) = store()

        await store.load(snapshot: snapshot([run("main", number: 4, minutesAgo: 3, branch: "main")]), now: now)

        #expect(store.openPullRequests?.isEmpty == true)
        #expect(await transport.requests.isEmpty)
    }

    @Test func aFailedListStaysUnknownRatherThanEmpty() async throws {
        let (store, _) = store(pullRequestsStatus: 500)

        await store.load(snapshot: snapshot([run("pr", number: 2, minutesAgo: 1, branch: "a", pullRequest: (128, nil))]), now: now)

        #expect(store.openPullRequests == nil && store.loadFailed)
    }

    // MARK: - Navigation

    @Test func theReferencesViewHasAnAddressAndItsScopeFollowsTheSidebar() throws {
        let navigation = NavigationModel()
        let url = try #require(CumulusURL.references)

        #expect(CumulusURL.destination(of: url) == .references)
        #expect(CumulusURL.destination(of: URL(string: "cumulus://references/x")!) == nil)
        #expect(navigation.open(url))
        #expect(navigation.sidebarSelection == .references)

        navigation.referenceScope = .branchOrTag("main")
        navigation.selectedBuildID = "r1"
        navigation.referenceScope = .pullRequest(7)
        #expect(navigation.selectedBuildID == nil, "another reference's list: the build of the one before is gone")

        navigation.selectedBuildID = "r2"
        navigation.accountDidChange()
        #expect(navigation.sidebarSelection == .references && navigation.referenceScope == nil && navigation.selectedBuildID == nil)

        navigation.referenceScope = .pullRequest(7)
        navigation.sidebarSelection = .allBuilds
        #expect(navigation.referenceScope == nil, "leaving the view forgets the reference")
    }
}
