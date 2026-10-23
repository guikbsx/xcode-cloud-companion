import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewDayDetailTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let english = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Thursday 23 October 2026, 14:32.
    private var now: Date { date(10, 23, 14, 32) }
    private var words: OverviewDayWords { OverviewDayWords(locale: english, calendar: calendar) }

    private func run(
        _ number: Int, at created: Date, minutes: Double = 10, progress: CIExecutionProgress = .complete,
        status: CICompletionStatus? = .succeeded, workflow: String = "w"
    ) -> CIBuildRun {
        let started: Date? = progress == .pending ? nil : created
        return CIBuildRun(
            id: "\(workflow)-\(number)", productID: "p", number: number, createdDate: created, startedDate: started,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: workflow, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func detail(
        _ runs: [CIBuildRun], day: Date? = nil, categories: [String: FailureCategory] = [:], insights: [String: String] = [:]
    ) -> OverviewDayDetail? {
        var workflow = CIWorkflow(id: "w", name: "Nightly", testDestinationCounts: [])
        workflow.productID = "p"
        let snapshot = BuildSnapshot(
            products: [CIProduct(id: "p", name: "Sextant", productType: "APP", appID: nil, appName: nil, bundleID: nil)], runs: runs, workflows: [workflow]
        )
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
        let mosaic = OverviewMosaic(snapshot: snapshot, sidebar: sidebar, now: now, calendar: calendar)
        guard let group = mosaic.groups.first, let row = group.rows.first else { return nil }
        return OverviewDayDetail(
            day: day ?? date(10, 21, 9), row: row, appName: group.name, snapshot: snapshot, now: now, calendar: calendar,
            categories: categories, insights: insights
        )
    }

    // MARK: - Sentence

    @Test func theSentenceFollowsTheCountsAndTheirPlural() throws {
        let one = try #require(detail([run(203, at: date(10, 21, 2), status: .failed)]))
        #expect(words.summary(one.cell) == "1 build, failed")

        let all = try #require(detail([run(1, at: date(10, 21, 2), status: .failed), run(2, at: date(10, 21, 3), status: .errored)]))
        #expect(words.summary(all.cell) == "2 builds, all failed")

        let mixed = try #require(detail([
            run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3)), run(3, at: date(10, 21, 4), status: .failed),
        ]))
        #expect(words.summary(mixed.cell) == "3 builds, 1 failure")
        let twice = try #require(detail([
            run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3), status: .failed), run(3, at: date(10, 21, 4), status: .failed),
        ]))
        #expect(words.summary(twice.cell) == "3 builds, 2 failures")

        let fine = try #require(detail([run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3))]))
        #expect(words.summary(fine.cell) == "2 builds, all succeeded")
        let single = try #require(detail([run(1, at: date(10, 21, 2))]))
        #expect(words.summary(single.cell) == "1 build, succeeded")
    }

    @Test func aDayWithoutBuildSaysSoAndOffersNothingToOpen() throws {
        let empty = try #require(detail([run(1, at: date(10, 23, 9))], day: date(10, 20)))

        #expect(words.summary(empty.cell) == "No build that day")
        #expect(empty.isEmpty && empty.lines.isEmpty && empty.openRunID == nil && empty.hiddenCount == 0 && empty.insight == nil)
    }

    @Test func buildsStillGoingOrCanceledGetTheirOwnSentence() throws {
        let going = try #require(detail([run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3), progress: .running, status: nil)], day: date(10, 21)))
        #expect(words.summary(going.cell) == "2 builds, 1 in progress")

        let partly = try #require(detail([run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3), status: .canceled)]))
        #expect(words.summary(partly.cell) == "2 builds, 1 succeeded")

        let none = try #require(detail([run(1, at: date(10, 21, 2), status: .canceled), run(2, at: date(10, 21, 3), status: .skipped)]))
        #expect(words.summary(none.cell) == "2 builds, none finished")
    }

    @Test func theCellOfTheMosaicAndTheBuildsListedAgree() throws {
        let runs = (1...5).map { run($0, at: date(10, 21, 6 + $0)) } + [run(9, at: date(10, 22, 9)), run(10, at: date(10, 20, 23, 59))]

        let result = try #require(detail(runs))

        #expect(result.cell.builds == 5)
        #expect(result.lines.count + result.hiddenCount == result.cell.builds)
    }

    @Test func aDayThatIsNotAColumnGivesNothing() throws {
        #expect(detail([run(1, at: date(10, 21, 2))], day: date(1, 5)) == nil)
    }

    // MARK: - Lines

    @Test func aLineGivesNumberStartDurationAndCategoryOfAFailure() throws {
        let failed = run(203, at: date(10, 21, 2), minutes: 18, status: .failed)

        let result = try #require(detail([failed], categories: ["w-203": .tests]))

        let line = try #require(result.lines.first)
        #expect(line.status == .failed && line.state == .finished && line.duration == 18 * 60 && line.category == .tests)
        #expect(words.line(line) == "#203 · 2:00\u{202F}AM · 18 min · Tests")
        #expect(words.spokenLine(line) == "Failed, #203 · 2:00\u{202F}AM · 18 min · Tests")
    }

    @Test func aCategoryIsOnlyShownForAFailureAndOnlyWhenKnown() throws {
        let runs = [run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3), status: .failed), run(3, at: date(10, 21, 4), status: .errored)]

        let result = try #require(detail(runs, categories: ["w-1": .tests, "w-2": .compilation]))

        let byNumber = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.number ?? 0, $0) })
        #expect(byNumber[1]?.category == nil, "a success has none, even if one is in memory")
        #expect(byNumber[2]?.category == .compilation)
        #expect(byNumber[3]?.category == nil, "unknown stays unknown")
    }

    @Test func aBuildGoingOrWaitingSaysItsStateInsteadOfADuration() throws {
        let runs = [
            run(1, at: date(10, 21, 8), progress: .running, status: nil),
            run(2, at: date(10, 21, 9), progress: .pending, status: nil),
        ]

        let result = try #require(detail(runs))

        let waiting = try #require(result.lines.first)
        let running = try #require(result.lines.last)
        #expect(waiting.number == 2 && waiting.state == .queued && waiting.start == nil && waiting.duration == nil)
        #expect(words.line(waiting) == "#2 · Queued")
        #expect(running.state == .running && running.duration == nil)
        #expect(words.line(running) == "#1 · 8:00\u{202F}AM · Running")
    }

    @Test func aCanceledBuildKeepsItsStateWordWhenItHasNoDuration() throws {
        let canceled = CIBuildRun(
            id: "w-7", productID: "p", number: 7, createdDate: date(10, 21, 9), startedDate: nil, finishedDate: nil, executionProgress: .complete,
            completionStatus: .canceled, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
        )

        let line = try #require(detail([canceled])?.lines.first)

        #expect(words.line(line) == "#7 · Canceled")
    }

    @Test func linesAreNewestFirstAndCutAtEightWithTheRestCounted() throws {
        let runs = (1...11).map { run($0, at: date(10, 21, $0)) }

        let result = try #require(detail(runs))

        #expect(result.lines.count == OverviewDayDetail.maximumLines)
        #expect(result.lines.map(\.number) == [11, 10, 9, 8, 7, 6, 5, 4])
        #expect(result.hiddenCount == 3)
        #expect(words.andMore(result.hiddenCount) == "and 3 more")
    }

    @Test func otherWorkflowsAndOtherDaysAreNotListed() throws {
        let runs = [run(1, at: date(10, 21, 2)), run(2, at: date(10, 21, 3), workflow: "other"), run(3, at: date(10, 22, 3))]

        let result = try #require(detail(runs))

        #expect(result.lines.map(\.number) == [1])
    }

    // MARK: - Open

    @Test func theBuildToOpenIsTheLastOfTheDay() throws {
        let runs = [run(5, at: date(10, 21, 2), status: .failed), run(6, at: date(10, 21, 14)), run(4, at: date(10, 21, 1))]

        let result = try #require(detail(runs))

        #expect(result.openRunID == "w-6" && result.openNumber == 6)
        #expect(words.openLabel(number: result.openNumber) == "Open #6")
        #expect(words.openLabel(number: nil) == "Open build")
    }

    // MARK: - In brief

    @Test func theSentenceOfAFailureIsShownWhenGiven() throws {
        let failed = run(203, at: date(10, 21, 2), status: .failed)

        let result = try #require(detail([failed], insights: ["w-203": "Four RouteSolver tests fail since iOS 27."]))

        #expect(result.insight == OverviewDayDetail.Insight(runID: "w-203", number: 203, text: "Four RouteSolver tests fail since iOS 27."))
    }

    @Test func noSentenceIsShownWhenNoneIsGivenOrTheBuildDidNotFail() throws {
        let runs = [run(203, at: date(10, 21, 2), status: .failed), run(204, at: date(10, 21, 3))]

        #expect(try #require(detail(runs)).insight == nil)
        #expect(try #require(detail(runs, insights: ["w-204": "Not a failure."])).insight == nil)
        #expect(try #require(detail(runs, insights: ["w-203": ""])).insight == nil)
    }

    @Test func theNewestFailedBuildWithASentenceSpeaks() throws {
        let runs = [run(1, at: date(10, 21, 2), status: .failed), run(2, at: date(10, 21, 3), status: .failed)]

        let result = try #require(detail(runs, insights: ["w-1": "First.", "w-2": "Second."]))

        #expect(result.insight?.runID == "w-2")
    }

    // MARK: - Words

    @Test func theDayIsWrittenInFullWithACapital() throws {
        let result = try #require(detail([run(1, at: date(10, 21, 2))]))

        #expect(words.longDay(result.day) == "Wednesday, October 21")
        #expect(words.workflowLine(result) == "Sextant · Nightly")
        #expect(words.spokenHeader(result) == "Sextant · Nightly, Wednesday, October 21. 1 build, succeeded")
    }
}
