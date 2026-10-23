import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildListModelTests {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    /// Friday 9 October 2026, 00:30 in Paris (Thursday 22:30 UTC).
    private var now: Date { Date(timeIntervalSince1970: 1_791_498_600) }
    private let english = Locale(identifier: "en_US")

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? .distantPast
    }

    private func run(
        _ number: Int, product: String = "a", workflow: String? = "w", created: String, finished: Bool = true,
        status: CICompletionStatus? = .succeeded, testFailures: Int? = nil, branch: String? = "main", sha: String? = nil
    ) -> CIBuildRun {
        let start = date(created)
        var run = CIBuildRun(
            id: "run-\(number)", productID: product, number: number, createdDate: start, startedDate: start,
            finishedDate: finished ? start.addingTimeInterval(372) : nil, executionProgress: finished ? .complete : .running,
            completionStatus: finished ? status : nil, startReason: nil, workflowID: workflow, workflowName: "Release", sourceBranchOrTag: branch
        )
        run.issueCounts = testFailures.map { CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: $0, warnings: 0) }
        run.sourceCommit = sha.map { CISourceCommit(commitSha: $0, message: nil, authorName: nil, webURL: nil) }
        return run
    }

    private func model(_ runs: [CIBuildRun], scope: BuildListScope = .allBuilds, filter: BuildFilter = .all, query: String = "") -> BuildListModel {
        var workflow = CIWorkflow(id: "w", name: "Release", testDestinationCounts: [])
        workflow.actions = [CIWorkflowAction(name: "Archive", actionType: .archive, destination: nil, buildDistributionAudience: "INTERNAL_ONLY", scheme: nil, platform: nil, isRequiredToPass: nil)]
        let snapshot = BuildSnapshot(
            products: [
                CIProduct(id: "a", name: "Alpha", productType: "APP", appID: "1", appName: nil, bundleID: nil),
                CIProduct(id: "b", name: "Beta", productType: "APP", appID: "2", appName: nil, bundleID: nil),
            ],
            runs: runs, workflows: [workflow]
        )
        return BuildListModel(snapshot: snapshot, scope: scope, filter: filter, query: query, now: now, calendar: paris, locale: english)
    }

    @Test func aWorkflowDayListsThatWorkflowsBuildsOfThatDayOnly() {
        // 23:30 UTC on Wednesday is 01:30 on Thursday in Paris: the day of the second and third runs.
        let list = model(
            [
                run(1, created: "2026-10-07T12:00:00Z"), run(2, created: "2026-10-07T23:30:00Z"), run(3, created: "2026-10-08T09:00:00Z"),
                run(4, workflow: "other", created: "2026-10-08T10:00:00Z"), run(5, created: "2026-10-09T09:00:00Z"),
            ],
            scope: .workflowDay("w", date("2026-10-08T12:00:00Z"))
        )

        #expect(list.rows.map(\.number) == [3, 2])
        #expect(list.title == "Release · Thursday, October 8")
        #expect(list.emptyReason == nil)
    }

    @Test func aWorkflowDayWithoutBuildsIsEmpty() {
        let list = model([run(1, created: "2026-10-07T12:00:00Z")], scope: .workflowDay("w", date("2026-10-08T12:00:00Z")))

        #expect(list.rows.isEmpty)
        #expect(list.emptyReason == .noBuilds)
    }

    @Test func buildsAreGroupedByDayInTheUsersTimeZoneAroundMidnight() {
        // 23:50 UTC on Wednesday is 01:50 on Thursday in Paris, so yesterday; 22:10 UTC Thursday is 00:10 Friday: today.
        let list = model([
            run(1, created: "2026-10-08T22:10:00Z"), run(2, created: "2026-10-07T23:50:00Z"),
            run(3, created: "2026-10-05T12:00:00Z"), run(4, created: "2026-09-20T12:00:00Z"),
        ])

        #expect(list.groups.map(\.key) == [.today, .yesterday, .thisWeek, .month(year: 2026, month: 9)])
        #expect(list.groups.map(\.title) == ["Today", "Yesterday", "This week", "September 2026"])
        #expect(list.groups.map { $0.rows.map(\.number) } == [[1], [2], [3], [4]])
    }

    @Test func newestFirstThenByNumber() {
        let list = model([run(1, created: "2026-10-08T10:00:00Z"), run(3, created: "2026-10-08T10:00:00Z"), run(2, created: "2026-10-08T11:00:00Z")])

        #expect(list.rows.map(\.number) == [2, 3, 1])
    }

    @Test func theScopeNarrowsTheListAndNamesIt() {
        let runs = [run(1, product: "a", created: "2026-10-08T10:00:00Z"), run(2, product: "b", workflow: nil, created: "2026-10-08T11:00:00Z")]

        #expect(model(runs, scope: .product("b")).rows.map(\.number) == [2])
        #expect(model(runs, scope: .product("b")).title == "Beta")
        #expect(model(runs, scope: .workflow("w")).rows.map(\.number) == [1])
        #expect(model(runs, scope: .workflow("w")).title == "Release")
    }

    @Test func filtersKeepRunningFailedAndTestFlightBuilds() {
        let runs = [
            run(1, created: "2026-10-08T10:00:00Z"), run(2, created: "2026-10-08T11:00:00Z", finished: false),
            run(3, created: "2026-10-08T12:00:00Z", status: .failed), run(4, created: "2026-10-08T13:00:00Z", status: .errored),
        ]

        #expect(model(runs, filter: .running).rows.map(\.number) == [2])
        #expect(Set(model(runs, filter: .failed).rows.compactMap(\.number)) == [3, 4])
        #expect(model(runs, filter: .testFlight).count == 4)
    }

    @Test func searchFindsByNumberCommitAndName() {
        let runs = [
            run(41, created: "2026-10-08T10:00:00Z", sha: "ab12cd34ef"), run(7, created: "2026-10-08T11:00:00Z", branch: "feature/login"),
        ]

        #expect(model(runs, query: "#41").rows.map(\.number) == [41])
        #expect(model(runs, query: "ab12c").rows.map(\.number) == [41])
        #expect(model(runs, query: "login").rows.map(\.number) == [7])
        #expect(model(runs, query: "zzz").count == 0)
    }

    @Test func aCardIsNamedAfterItsCommitAndFallsBackOnHowItWent() {
        var named = run(1, created: "2026-10-08T22:10:00Z", status: .failed, testFailures: 3, sha: "abc1234")
        named.sourceCommit?.message = "Fix the CSV import\n\nA longer explanation."
        var blank = run(2, created: "2026-10-08T22:00:00Z", sha: "def5678")
        blank.sourceCommit?.message = "  \n"
        let rows = model([named, blank, run(3, created: "2026-10-08T21:00:00Z")]).rows

        #expect(rows.map(\.commitTitle) == ["Fix the CSV import", nil, nil])
        #expect(rows[0].facts == "Release · main" && rows[0].age(now: now) == "20m")

        let card = BuildCard(row: rows[0], now: now, swatch: .blue, artwork: nil, isSelected: false)
        #expect(card.title == "Fix the CSV import" && card.prefix == "#1" && card.statusText == "Failed · 3 tests")
        #expect(card.spokenLabel == "Fix the CSV import, #1, Failed · 3 tests" && card.spokenValue == "Alpha · Release · main")

        // No message from Apple: the card keeps saying how the build went, once.
        let fallback = BuildCard(row: rows[1], now: now, swatch: .blue, artwork: nil, isSelected: false)
        #expect(fallback.title == "Succeeded · TestFlight" && fallback.statusText == nil)
        #expect(String(BuildCard.line(prefix: "#1", statusText: "Failed", facts: "Release · main", tint: nil).characters) == "#1 · Failed · Release · main")
        #expect(String(BuildCard.line(prefix: "#2", statusText: nil, facts: "Release · main", tint: nil).characters) == "#2 · Release · main")
    }

    @Test func searchFindsACommitByItsMessage() {
        var named = run(1, created: "2026-10-08T22:10:00Z", sha: "abc1234")
        named.sourceCommit?.message = "Fix the CSV import"

        #expect(model([named, run(2, created: "2026-10-08T22:00:00Z")], query: "csv").rows.map(\.number) == [1])
    }

    @Test func rowsSaySoInWords() {
        let list = model([
            run(1, created: "2026-10-08T10:00:00Z", status: .failed, testFailures: 3),
            run(2, created: "2026-10-08T11:00:00Z"),
            run(3, created: "2026-10-08T22:00:00Z", finished: false),
        ])
        let byNumber = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.number ?? 0, $0) })

        #expect(byNumber[1]?.summary(now: now) == "Failed · 3 tests")
        #expect(byNumber[2]?.summary(now: now) == "Succeeded · TestFlight")
        #expect(byNumber[3]?.summary(now: now).hasPrefix("Running · ") == true)
        #expect(byNumber[2]?.duration(now: now) == "6:12")
        #expect(byNumber[2]?.detail == "Alpha · Release · main")
    }

    @Test func aRunningBuildsDurationGrowsWithTheClock() throws {
        let row = try #require(model([run(1, created: "2026-10-08T22:00:00Z", finished: false)]).rows.first)

        #expect(row.duration(now: now) == "30:00")
        #expect(row.duration(now: now.addingTimeInterval(65)) == "31:05")
        #expect(BuildRowData.clock(3725) == "1:02:05")
    }

    @Test func onlyARunningBuildsCounterGoesOnAndOnlyUntilItEnds() throws {
        let running = try #require(model([run(1, created: "2026-10-08T22:00:00Z", finished: false)]).rows.first)
        let finished = try #require(model([run(2, created: "2026-10-08T22:00:00Z")]).rows.first)

        #expect(running.runningSince == running.startedDate && running.runningSince != nil)
        #expect(finished.runningSince == nil)
    }

    @Test func theEmptyListSaysWhy() {
        #expect(model([]).emptyReason == .noBuilds)
        #expect(model([run(1, created: "2026-10-08T10:00:00Z")], filter: .running).emptyReason == .nothingMatches)
        #expect(model([run(1, created: "2026-10-08T10:00:00Z")]).emptyReason == nil)
    }
}
