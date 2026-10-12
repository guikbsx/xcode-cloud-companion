import AppKit
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

struct DetailColumnsTests {
    private typealias Slot = DetailColumnsGeometry.Slot

    /// Every group is as wide as what it is offered and 100 points tall, unless a height says otherwise.
    private func geometry(
        _ placements: [DetailPlacement], width: CGFloat? = 1000, columns: DetailColumns = .two, sideWidth: CGFloat? = DetailColumns.sideWidth,
        equalHeights: Bool = false, heights: [Int: CGFloat] = [:]
    ) -> DetailColumnsGeometry {
        DetailColumnsGeometry(placements: placements, width: width, columns: columns, spacing: 18, sideWidth: sideWidth, equalHeights: equalHeights) { index, width in
            CGSize(width: width ?? 300, height: heights[index] ?? 100)
        }
    }

    @Test func twoColumnsStartAt880Points() {
        #expect(DetailColumns(width: 879) == .one)
        #expect(DetailColumns(width: 879.5) == .one)
        #expect(DetailColumns(width: 880) == .two)
        #expect(DetailColumns(width: 320) == .one)
        #expect(DetailColumns(width: 2000) == .two)
    }

    @Test func onOneColumnTheGroupsFollowEachOtherAsDeclared() {
        let geometry = geometry([.full, .main, .side, .main], width: 600, columns: .one)

        #expect(geometry.slots == [
            Slot(x: 0, y: 0, width: 600), Slot(x: 0, y: 118, width: 600), Slot(x: 0, y: 236, width: 600), Slot(x: 0, y: 354, width: 600),
        ])
        #expect(geometry.size == CGSize(width: 600, height: 454))
    }

    @Test func onTwoColumnsTheSideGroupsStandBesideTheMainOnes() {
        let geometry = geometry([.main, .side, .side, .main])

        // 1000 − 340 − 18 for the main column; the side one starts where it ends, a gap further.
        #expect(geometry.slots == [
            Slot(x: 0, y: 0, width: 642), Slot(x: 660, y: 0, width: 340), Slot(x: 660, y: 118, width: 340), Slot(x: 0, y: 118, width: 642),
        ])
        #expect(geometry.size == CGSize(width: 1000, height: 218))
    }

    @Test func theTallerColumnGivesTheSheetItsHeight() {
        let geometry = geometry([.main, .side], heights: [0: 400, 1: 120])

        #expect(geometry.size.height == 400)
    }

    @Test func aGroupAcrossBothColumnsSeparatesWhatComesBeforeFromWhatFollows() {
        let geometry = geometry([.full, .main, .side, .full, .main, .side], heights: [1: 300])

        #expect(geometry.slots[0] == Slot(x: 0, y: 0, width: 1000))
        #expect(geometry.slots[1] == Slot(x: 0, y: 118, width: 642))
        #expect(geometry.slots[2] == Slot(x: 660, y: 118, width: 340))
        // Under the taller of the two columns above it.
        #expect(geometry.slots[3] == Slot(x: 0, y: 436, width: 1000))
        #expect(geometry.slots[4] == Slot(x: 0, y: 554, width: 642))
        #expect(geometry.slots[5] == Slot(x: 660, y: 554, width: 340))
    }

    @Test func withNothingForTheSideColumnTheSheetStaysOnOne() {
        let geometry = geometry([.main, .main])

        #expect(geometry.slots == [Slot(x: 0, y: 0, width: 1000), Slot(x: 0, y: 118, width: 1000)])
    }

    @Test func withNothingForTheMainColumnTheSideGroupsTakeTheWholeWidth() {
        let geometry = geometry([.full, .side])

        #expect(geometry.slots == [Slot(x: 0, y: 0, width: 1000), Slot(x: 0, y: 118, width: 1000)])
    }

    @Test func aGroupThatDrawsNothingLeavesNoGap() {
        let geometry = geometry([.main, .main, .main], width: 600, columns: .one, heights: [1: 0])

        #expect(geometry.slots[2].y == 118)
        #expect(geometry.size.height == 218)
    }

    @Test func halvesShareTheWidthEqually() {
        let geometry = geometry([.main, .side], sideWidth: nil)

        #expect(geometry.slots == [Slot(x: 0, y: 0, width: 491), Slot(x: 509, y: 0, width: 491)])
    }

    @Test func twoGroupsSideBySideCanBeGivenTheSameHeight() {
        let geometry = geometry([.main, .side, .full, .main, .side, .side], sideWidth: nil, equalHeights: true, heights: [0: 160, 1: 90])

        #expect(geometry.slots[0].height == 160)
        #expect(geometry.slots[1].height == 160)
        // A column of several groups keeps their own heights: only a lone group is stretched.
        #expect(geometry.slots[3].height == 218)
        #expect(geometry.slots[4].height == nil)
        #expect(geometry.slots[5].height == nil)
    }

    /// Asked what it would take by itself, as the window does to find its smallest size: one column, as wide as its widest group.
    @Test func withoutAWidthTheSheetIsOneColumn() {
        let geometry = geometry([.main, .side], width: nil)

        #expect(geometry.slots == [Slot(x: 0, y: 0), Slot(x: 0, y: 118)])
        #expect(geometry.size == CGSize(width: 300, height: 218))
    }

    @Test func anEmptySheetTakesNoRoom() {
        #expect(geometry([]).size == CGSize(width: 1000, height: 0))
    }
}

/// The container in a real window: it reads its own width, and resizing across the threshold moves the groups without
/// making new ones.
@MainActor
struct DetailScrollTests {
    private final class Record {
        var columns: [DetailColumns] = []
        var tasks = 0
        var appearances = 0
    }

    private func window(_ record: Record, width: CGFloat) -> NSWindow {
        let hosting = NSHostingController(rootView: DetailScroll { columns in
            let _ = record.columns.append(columns)
            Text(verbatim: "Main")
                .task { record.tasks += 1 }
                .onAppear { record.appearances += 1 }
            Text(verbatim: "Side")
                .detailPlacement(.side)
        })
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: width, height: 400))
        window.orderFront(nil)
        return window
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    @Test func theSheetIsToldTwoColumnsFromItsOwnWidth() async throws {
        let record = Record()
        let window = window(record, width: 879)
        defer { window.close() }
        try await settle()
        #expect(record.columns.last == .one)

        window.setContentSize(NSSize(width: 880, height: 400))
        try await settle()
        #expect(record.columns.last == .two)

        window.setContentSize(NSSize(width: 600, height: 400))
        try await settle()
        #expect(record.columns.last == .one)
    }

    /// What a group started when it appeared is not started again: no request leaves because the window was resized.
    @Test func crossingTheThresholdKeepsTheGroupsAndTheirTasks() async throws {
        let record = Record()
        let window = window(record, width: 700)
        defer { window.close() }
        try await settle()

        for width in [1200, 700, 1200, 879, 880] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 400))
            try await settle()
        }

        #expect(record.columns.last == .two)
        #expect(record.tasks == 1)
        #expect(record.appearances == 1)
    }

    /// The sheet is redrawn when the number of columns changes, not at every point of a resize.
    @Test func resizingWithinAModeDoesNotRedrawTheSheet() async throws {
        let record = Record()
        let window = window(record, width: 1000)
        defer { window.close() }
        try await settle()
        let drawn = record.columns.count

        for width in [1010, 1100, 1300, 950] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 400))
            try await settle()
        }

        #expect(record.columns.count == drawn)
    }
}
