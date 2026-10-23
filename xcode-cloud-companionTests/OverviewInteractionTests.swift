import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewInteractionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private var now: Date { date(10, 23, 14) }

    private struct Fixture {
        let source: OverviewDetailSource
        let rows: [OverviewMosaic.Row]
        let group: OverviewMosaic.Group
    }

    /// Two workflows of one app, by name; the first ran a slow stretch of builds, so `WorkflowSlowdown` finds a step.
    private func fixture(pro: Set<ProFeature> = Set(ProFeature.allCases)) -> Fixture {
        var runs: [CIBuildRun] = []
        var number = 0
        for offset in 0..<20 {
            let day = date(10, 23, 9).addingTimeInterval(Double(-(19 - offset)) * 86_400)
            number += 1
            let minutes: Double = offset < 10 ? 8 : 14
            runs.append(CIBuildRun(
                id: "w-\(number)", productID: "p", number: number, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(minutes * 60),
                executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: "Alpha", sourceBranchOrTag: nil
            ))
        }
        runs.append(CIBuildRun(
            id: "m-1", productID: "p", number: 1, createdDate: date(10, 22, 9), startedDate: date(10, 22, 9), finishedDate: date(10, 22, 9).addingTimeInterval(300),
            executionProgress: .complete, completionStatus: .failed, startReason: nil, workflowID: "m", workflowName: "Beta", sourceBranchOrTag: nil
        ))
        var nightly = CIWorkflow(id: "w", name: "Alpha", testDestinationCounts: [])
        nightly.productID = "p"
        var main = CIWorkflow(id: "m", name: "Beta", testDestinationCounts: [])
        main.productID = "p"
        let snapshot = BuildSnapshot(
            products: [CIProduct(id: "p", name: "Sextant", productType: "APP", appID: nil, appName: nil, bundleID: nil)], runs: runs, workflows: [nightly, main]
        )
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
        let mosaic = OverviewMosaic(snapshot: snapshot, sidebar: sidebar, now: now, calendar: calendar)
        let group = mosaic.groups[0]
        return Fixture(
            source: OverviewDetailSource(snapshot: snapshot, now: now, calendar: calendar, pro: pro), rows: group.rows, group: group
        )
    }

    private func bubble(_ fixture: Fixture, row: Int = 0, column: Int = 34) -> OverviewFigureInteraction.Bubble? {
        let row = fixture.rows[row]
        let cell = row.cells[column]
        return fixture.source.dayDetail(row: row, appName: fixture.group.name, day: cell.day).map {
            OverviewFigureInteraction.Bubble(spot: .init(rowID: row.id, column: column), detail: $0, swatch: .blue, productID: "p")
        }
    }

    private func drawer(_ fixture: Fixture, row: Int = 0) -> OverviewFigureInteraction.Drawer? {
        fixture.source.durationSeries(row: fixture.rows[row]).map { OverviewFigureInteraction.Drawer(rowID: fixture.rows[row].id, series: $0) }
    }

    // MARK: Source

    @Test func theDrawerIsCumulusProsAndTheBubbleIsNot() {
        let free = fixture(pro: [])
        #expect(!free.source.allowsDrawer)
        #expect(free.source.durationSeries(row: free.rows[0]) == nil)
        #expect(bubble(free) != nil)

        let pro = fixture(pro: [.workflowTrends])
        #expect(pro.source.allowsDrawer)
        #expect(pro.source.durationSeries(row: pro.rows[0]) != nil)
    }

    @Test func theSourceAnswersWithoutAnythingButTheSnapshot() throws {
        let fixture = fixture()
        let series = try #require(fixture.source.durationSeries(row: fixture.rows[0]))
        #expect(series.points.count == OverviewMosaic.defaultDays)
        #expect(series.step != nil)
        let detail = try #require(fixture.source.dayDetail(row: fixture.rows[0], appName: "Sextant", day: date(10, 23)))
        #expect(detail.lines.count == 1)
    }

    // MARK: State

    @Test func aClickOpensTheBubbleAtOnceAndOpeningAnotherReplacesIt() throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.openBubble(bubble(fixture, row: 0, column: 30))
        #expect(interaction.bubble?.spot.column == 30)
        #expect(interaction.litSpot == interaction.bubble?.spot)

        interaction.openBubble(bubble(fixture, row: 1, column: 12))
        #expect(interaction.bubble?.spot == .init(rowID: fixture.rows[1].id, column: 12))

        interaction.closeBubble()
        #expect(interaction.bubble == nil)
        #expect(interaction.litSpot == nil)
    }

    @Test func theSystemDismissingAPopoverClosesOnlyThatBubble() throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.openBubble(bubble(fixture, column: 30))
        let stale = "someone-else#1"
        interaction.bubbleWasDismissed(stale)
        #expect(interaction.bubble != nil)
        interaction.bubbleWasDismissed(try #require(interaction.bubble).id)
        #expect(interaction.bubble == nil)
    }

    @Test func onlyOneDrawerIsOpenAndTheButtonTogglesIt() throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.toggleDrawer(fixture.rows[0].id) { drawer(fixture, row: 0) }
        #expect(interaction.drawer?.rowID == fixture.rows[0].id)

        interaction.toggleDrawer(fixture.rows[1].id) { drawer(fixture, row: 1) }
        #expect(interaction.drawer?.rowID == fixture.rows[1].id)

        interaction.toggleDrawer(fixture.rows[1].id) { drawer(fixture, row: 1) }
        #expect(interaction.drawer == nil)
    }

    @Test func withoutProTheDrawerCannotOpen() {
        let fixture = fixture(pro: [])
        let interaction = OverviewFigureInteraction()
        interaction.toggleDrawer(fixture.rows[0].id) { drawer(fixture) }
        #expect(interaction.drawer == nil)
    }

    @Test func resetClosesBoth() {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.openBubble(bubble(fixture))
        interaction.toggleDrawer(fixture.rows[0].id) { drawer(fixture) }
        interaction.reset()
        #expect(interaction.bubble == nil)
        #expect(interaction.drawer == nil)
    }

    @Test func aPointerRestingOnASquareOpensItsBubbleAfterTheDelayAndLeavingClosesIt() async throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.delays = .init(open: .milliseconds(20), swap: .milliseconds(5), close: .milliseconds(20), drawerClose: .milliseconds(20))
        let spot = OverviewFigureInteraction.Spot(rowID: fixture.rows[0].id, column: 33)
        interaction.pointerEntered(spot) { bubble(fixture, column: 33) }
        #expect(interaction.bubble == nil)
        try await waitUntil { interaction.bubble != nil }
        #expect(interaction.bubble?.spot == spot)

        interaction.pointerLeftSquares()
        try await waitUntil { interaction.bubble == nil }
    }

    @Test func leavingBeforeTheDelayOpensNothingAndReachingTheBubbleKeepsItOpen() async throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.delays = .init(open: .milliseconds(60), swap: .milliseconds(5), close: .milliseconds(40), drawerClose: .milliseconds(40))
        interaction.pointerEntered(.init(rowID: fixture.rows[0].id, column: 33)) { bubble(fixture, column: 33) }
        interaction.pointerLeftSquares()
        try await Task.sleep(for: .milliseconds(150))
        #expect(interaction.bubble == nil)

        interaction.openBubble(bubble(fixture, column: 33))
        interaction.pointerLeftSquares()
        interaction.pointerInBubble(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(interaction.bubble != nil)
        interaction.pointerInBubble(false)
        try await waitUntil { interaction.bubble == nil }
    }

    @Test func theDrawerOpensAfterTheDelayOnTheNameAndClosesWhenThePointerLeavesTheFigure() async throws {
        let fixture = fixture()
        let interaction = OverviewFigureInteraction()
        interaction.delays = .init(open: .milliseconds(20), swap: .milliseconds(5), close: .milliseconds(20), drawerClose: .milliseconds(30))
        interaction.pointerEnteredName(fixture.rows[0].id) { drawer(fixture) }
        try await waitUntil { interaction.drawer != nil }

        interaction.pointerLeftName()
        interaction.pointerLeftFigure()
        interaction.pointerEnteredFigure()
        try await Task.sleep(for: .milliseconds(120))
        #expect(interaction.drawer != nil)

        interaction.pointerLeftFigure()
        try await waitUntil { interaction.drawer == nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The condition was not met in two seconds.")
    }

    // MARK: Navigation

    @Test func seeingADayListsItAndAnotherSelectionLeavesIt() {
        let navigation = NavigationModel()
        navigation.sidebarSelection = .overview
        navigation.showDay(workflowID: "w", day: date(10, 21))
        #expect(navigation.sidebarSelection == .allBuilds)
        #expect(navigation.daySlice == WorkflowDay(workflowID: "w", day: date(10, 21)))
        #expect(navigation.selectedBuildID == nil)

        navigation.sidebarSelection = .overview
        #expect(navigation.daySlice == nil)
    }

    @Test func openingABuildLeavesTheDayList() {
        let navigation = NavigationModel()
        navigation.showDay(workflowID: "w", day: date(10, 21))
        navigation.showBuild("run-1")
        #expect(navigation.daySlice == nil)
        #expect(navigation.selectedBuildID == "run-1")
    }
}
