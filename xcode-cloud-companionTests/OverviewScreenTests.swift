import Foundation
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewScreenTests {
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

    // MARK: - A small account

    private func run(
        _ number: Int, at created: Date, minutes: Double = 10, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded,
        workflow: String = "w", product: String = "p"
    ) -> CIBuildRun {
        CIBuildRun(
            id: "\(workflow)-\(number)", productID: product, number: number, createdDate: created, startedDate: progress == .pending ? nil : created,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: workflow, workflowName: "Nightly", sourceBranchOrTag: nil
        )
    }

    private func snapshot(_ runs: [CIBuildRun]) -> BuildSnapshot {
        var workflow = CIWorkflow(id: "w", name: "Nightly", testDestinationCounts: [])
        workflow.productID = "p"
        return BuildSnapshot(
            products: [CIProduct(id: "p", name: "Sextant", productType: "APP", appID: nil, appName: nil, bundleID: nil)], runs: runs, workflows: [workflow],
            lastSuccessfulSync: now
        )
    }

    private func sidebar(_ snapshot: BuildSnapshot) -> SidebarContent {
        SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
    }

    /// Success on the 18th, then failures on the 21st, 22nd and 23rd: Sextant has been broken for two days.
    private var broken: BuildSnapshot {
        snapshot([
            run(202, at: date(10, 18, 2)), run(203, at: date(10, 21, 2), status: .failed), run(204, at: date(10, 22, 2), status: .errored),
            run(205, at: date(10, 23, 2), status: .failed),
        ])
    }

    private func model(_ snapshot: BuildSnapshot, summary: UsageSummary? = nil, reading: Bool = false) -> OverviewScreenModel {
        OverviewScreenModel(
            snapshot: snapshot, sidebar: sidebar(snapshot), summary: summary, accountName: "Atelier", isReading: reading, now: now, calendar: calendar, locale: english
        )
    }

    // MARK: - Layout

    @Test func theFigureShowsThirtyFiveDaysWhenItHasRoomAndFewerWhenItHasNot() {
        let widths: [(CGFloat, Int)] = [(1700, 35), (1200, 35), (1000, 21), (700, 14), (622, 14), (480, 7)]
        for (width, days) in widths {
            let layout = OverviewFigureLayout.make(width: width, showsCycle: true, hasNotes: true)
            #expect(layout.days == days, "\(width) pt")
        }
    }

    @Test func theFigureNeverGetsWiderThanItsColumnAboveTheLastResort() {
        for width in stride(from: 520.0, through: 2000.0, by: 7) {
            for showsCycle in [true, false] {
                let layout = OverviewFigureLayout.make(width: width, showsCycle: showsCycle, hasNotes: true)
                #expect(layout.figureWidth <= width, "\(width) pt, cycle \(showsCycle)")
                #expect(layout.pitch >= OverviewFigureLayout.minimumPitch)
            }
        }
    }

    @Test func squaresAreThreePointsApartAndNeverBiggerThanTheRowAllows() {
        let layout = OverviewFigureLayout.make(width: 1700, showsCycle: true, hasNotes: false)

        #expect(layout.pitch == OverviewFigureLayout.preferredPitch)
        #expect(layout.cellSide == 21)
        let expected: CGFloat = 837
        #expect(layout.cellsWidth == expected)
    }

    @Test func theNotesStandBesideTheFigureOnlyWhenTheyHaveRoomAndThereAreSome() {
        #expect(OverviewFigureLayout.make(width: 1700, showsCycle: true, hasNotes: true).notes == .beside)
        #expect(OverviewFigureLayout.make(width: 1700, showsCycle: true, hasNotes: false).notes == .below)
        #expect(OverviewFigureLayout.make(width: 1150, showsCycle: true, hasNotes: true).notes == .below)
        #expect(OverviewFigureLayout.make(width: 700, showsCycle: true, hasNotes: true).notes == .below, "fewer days: the notes go under the figure")
    }

    @Test func withoutAPlanTheCycleColumnLeavesRoomForDays() {
        let with = OverviewFigureLayout.make(width: 1030, showsCycle: true, hasNotes: false)
        let without = OverviewFigureLayout.make(width: 1030, showsCycle: false, hasNotes: false)

        #expect(with.days == 21)
        #expect(without.days == 35)
        #expect(without.figuresWidth < with.figuresWidth)
    }

    @Test func notesShareTheRowOnlyWhenEachHasRoom() {
        #expect(OverviewFigureLayout.noteColumns(count: 3, width: 760) == 3)
        #expect(OverviewFigureLayout.noteColumns(count: 3, width: 620) == 1)
        #expect(OverviewFigureLayout.noteColumns(count: 1, width: 300) == 1)
        #expect(OverviewFigureLayout.noteColumns(count: 0, width: 300) == 1)
    }

    // MARK: - The line at the top

    @Test func theLineNamesTheDayTheAccountAndWhatRuns() {
        let started = now.addingTimeInterval(-8 * 60)
        var runs = (0..<4).map { run(100 + $0, at: date(10, 10 + $0, 9), minutes: 12) }
        runs.append(run(412, at: started, progress: .running, status: nil))
        let line = OverviewAccountLine(snapshot: snapshot(runs), summary: nil, isMeasuring: false, accountName: "Atelier", now: now, calendar: calendar, locale: english)

        #expect(line.day == "Friday, October 23")
        #expect(line.account == "Atelier")
        #expect(line.running?.runID == "w-412")
        let text = line.running?.text ?? ""
        #expect(text.hasPrefix("Sextant #412 is running, ends around 2") && text.hasSuffix("PM (~4 min)"), "\(text)")
        #expect(line.plan == .missing)
    }

    @Test func aQueuedBuildAndSeveralBuildsAreSaidToo() {
        let queued = run(7, at: now.addingTimeInterval(-60), progress: .pending, status: nil)
        let running = run(8, at: now.addingTimeInterval(-120), progress: .running, status: nil)

        let one = OverviewAccountLine(snapshot: snapshot([queued]), summary: nil, isMeasuring: false, accountName: "A", now: now, calendar: calendar, locale: english)
        let two = OverviewAccountLine(snapshot: snapshot([queued, running]), summary: nil, isMeasuring: false, accountName: "A", now: now, calendar: calendar, locale: english)

        #expect(one.running?.text == "Sextant #7 is waiting in the queue")
        #expect(two.running?.text == "Sextant #8 is running, and 1 more")
    }

    @Test func theLineSaysNothingOfBuildsWhenNoneRuns() {
        let line = OverviewAccountLine(snapshot: broken, summary: nil, isMeasuring: false, accountName: "A", now: now, calendar: calendar, locale: english)

        #expect(line.running == nil)
    }

    @Test func thePlanIsWrittenOutMeasuredOrMissing() {
        let cycle = DateInterval(start: date(10, 5, 0), end: date(11, 5, 0))
        let summary = UsageSummary(
            plan: UsagePlan(hours: 25, resetAnchor: cycle.start), cycle: cycle, now: now, billedMinutes: 0, estimatedMinutes: 880, estimatedBuildCount: 4,
            lastImport: nil, daily: [], buildsLast30Days: 0, byApp: []
        )

        let set = OverviewAccountLine(snapshot: broken, summary: summary, isMeasuring: false, accountName: "A", now: now, calendar: calendar, locale: english)
        let measuring = OverviewAccountLine(snapshot: broken, summary: summary, isMeasuring: true, accountName: "A", now: now, calendar: calendar, locale: english)

        #expect(set.plan == .set(used: UsageFormat.minutes(880, locale: english), quota: UsageFormat.minutes(1500, locale: english), isEstimate: true))
        #expect(measuring.plan == .measuring)
    }

    // MARK: - What VoiceOver reads

    @Test func aRowIsReadAsOneSentenceThatSumsItUp() throws {
        let mosaic = model(broken).mosaic
        let row = try #require(mosaic.rows.first)
        let words = OverviewScreenWords(locale: english, calendar: calendar)

        let text = words.rowSummary(app: "Sextant", row: row, now: now)

        #expect(text.hasPrefix("Sextant, Nightly: failing for two days, "))
        #expect(text.contains("succeeded over 7 days"))
        #expect(text.contains("median"))
    }

    @Test func aPausedWorkflowIsReadAsPausedAndAPassingOneAsPassing() throws {
        let passing = snapshot([run(1, at: date(10, 22, 9)), run(2, at: date(10, 23, 9))])
        let row = try #require(model(passing).mosaic.rows.first)
        let words = OverviewScreenWords(locale: english, calendar: calendar)

        #expect(words.rowSummary(app: "Sextant", row: row, now: now).hasPrefix("Sextant, Nightly: passing, 100% succeeded over 7 days"))
    }

    // MARK: - The screen's states

    @Test func aBrokenWorkflowMakesTheHeadlineAndOutlinesItsRun() throws {
        let screen = model(broken)

        #expect(screen.phase == .ready)
        #expect(screen.title.situation == .broken)
        #expect(screen.title.tone == .alert)
        #expect(try #require(screen.mosaic.rows.first).failureSeries?.failureCount == 3)
    }

    @Test func whileTheBuildsAreReadTheTitleSaysSoAndTheMosaicIsAPlaceholder() {
        let screen = model(broken, reading: true)

        #expect(screen.phase == .reading)
        #expect(screen.title.text == "Cumulus is reading your builds.")
        #expect(screen.title.emphasized == "reading")
        #expect(screen.notes.isEmpty)
        #expect(screen.mosaic.days.count == OverviewMosaic.defaultDays)
        #expect(!screen.mosaic.isEmpty)
        #expect(!screen.mosaic.rows.contains { $0.failureSeries != nil }, "a skeleton shows no fact")
    }

    @Test func noBuildInThePeriodIsAnEmptyStateWithNoMosaic() {
        let screen = model(snapshot([run(1, at: date(8, 1, 9))]))

        #expect(screen.phase == .empty)
        #expect(screen.mosaic.isEmpty)
        #expect(screen.title.text == "No build in the last 35 days.")
        #expect(screen.title.emphasized == "No build")
        #expect(screen.notes.isEmpty)
    }

    @Test func theSkeletonRuleCoversTheFirstSyncAndTheMeasure() {
        #expect(SkeletonRules.overviewMosaic(isMeasuring: true, isFirstSync: false))
        #expect(SkeletonRules.overviewMosaic(isMeasuring: false, isFirstSync: true))
        #expect(!SkeletonRules.overviewMosaic(isMeasuring: false, isFirstSync: false))
    }

    @Test func onlyTheNewestFinishedBuildOfEachWorkflowIsQuotedWhenItFailed() {
        let other = run(9, at: date(10, 23, 3), status: .failed, workflow: "w2")
        let finished = snapshot(broken.runs + [other, run(300, at: date(10, 22, 3), workflow: "w2")])

        #expect(OverviewScreen<EmptyView>.failedHeads(in: finished) == ["w-205", "w2-9"])
        #expect(OverviewScreen<EmptyView>.failedHeads(in: snapshot([run(1, at: date(10, 22, 9), status: .failed), run(2, at: date(10, 23, 9))])).isEmpty)
    }
}
