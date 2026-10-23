import SwiftUI

/// How a sheet lays its groups out: on two columns once its own column is wide enough, one under the other below that.
nonisolated enum DetailColumns: Equatable, Sendable {
    case one, two

    /// The width of the sheet's column, margins included, from which its groups go on two columns.
    static let threshold: CGFloat = 880
    /// The second column, the one for short context.
    static let sideWidth: CGFloat = 340
    static let margin: CGFloat = 24

    init(width: CGFloat) {
        self = width >= Self.threshold ? .two : .one
    }
}

/// Where a group of a sheet goes once there are two columns. On one column, the groups follow each other as declared.
nonisolated enum DetailPlacement: Equatable, Sendable {
    /// Across both columns: what comes before it ends there, what follows starts under it.
    case full
    case main
    case side
}

/// Where each group of a sheet lands, worked out from the sizes the groups say they take.
nonisolated struct DetailColumnsGeometry: Equatable, Sendable {
    struct Slot: Equatable, Sendable {
        var x: CGFloat
        var y: CGFloat
        /// What the group is offered; nil lets it take what it wants.
        var width: CGFloat?
        var height: CGFloat?
    }

    private(set) var slots: [Slot]
    private(set) var size = CGSize.zero

    /// - Parameters:
    ///   - width: the room inside the margins; nil when the sheet is asked what it would take by itself.
    ///   - sideWidth: the second column's width; nil shares the room equally.
    ///   - equalHeights: a column holding one group gives it the height of the group beside it.
    ///   - measure: the size a group takes when offered a width.
    init(
        placements: [DetailPlacement], width: CGFloat?, columns: DetailColumns, spacing: CGFloat, sideWidth: CGFloat? = DetailColumns.sideWidth,
        equalHeights: Bool = false, measure: (Int, CGFloat?) -> CGSize
    ) {
        slots = Array(repeating: Slot(x: 0, y: 0), count: placements.count)
        var bottom: CGFloat = 0
        var widest: CGFloat = 0
        var placedAny = false

        func stack(_ indices: [Int], x: CGFloat, from top: CGFloat, width: CGFloat?) -> CGFloat {
            var y = top
            for index in indices {
                let size = measure(index, width)
                slots[index] = Slot(x: x, y: y, width: width)
                widest = max(widest, x + size.width)
                // A group that draws nothing takes no room and no gap.
                if size.height > 0 {
                    y += size.height + spacing
                    placedAny = true
                }
            }
            return y
        }

        var band: [Int] = []
        func flush() {
            guard !band.isEmpty else { return }
            defer { band = [] }
            let main = band.filter { placements[$0] == .main }
            let side = band.filter { placements[$0] == .side }
            guard columns == .two, let width, !main.isEmpty, !side.isEmpty else {
                bottom = stack(band, x: 0, from: bottom, width: width)
                return
            }
            let sideWidth = sideWidth ?? (width - spacing) / 2
            let mainWidth = width - spacing - sideWidth
            let mainBottom = stack(main, x: 0, from: bottom, width: mainWidth)
            let sideBottom = stack(side, x: mainWidth + spacing, from: bottom, width: sideWidth)
            let bandBottom = max(mainBottom, sideBottom)
            if equalHeights {
                let height = bandBottom - spacing - bottom
                for column in [main, side] where column.count == 1 && height > 0 {
                    slots[column[0]].height = height
                }
            }
            bottom = bandBottom
        }

        for (index, placement) in placements.enumerated() {
            if placement == .full {
                flush()
                bottom = stack([index], x: 0, from: bottom, width: width)
            } else {
                band.append(index)
            }
        }
        flush()
        size = CGSize(width: width ?? widest, height: placedAny ? bottom - spacing : 0)
    }
}

private nonisolated struct DetailPlacementKey: LayoutValueKey {
    static let defaultValue = DetailPlacement.main
}

extension View {
    /// Says which column a group of a sheet belongs to; a group that says nothing stays in the main one.
    func detailPlacement(_ placement: DetailPlacement) -> some View {
        layoutValue(key: DetailPlacementKey.self, value: placement)
    }
}

/// The groups of a sheet on one or two columns. A layout, not two stacks swapped for one another: a group keeps its
/// state and its tasks when the window is resized across the threshold, so nothing is asked of Apple again.
nonisolated struct DetailColumnsLayout: Layout {
    var columns = DetailColumns.one
    var spacing: CGFloat = 18
    var sideWidth: CGFloat? = DetailColumns.sideWidth
    var equalHeights = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        geometry(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = geometry(width: bounds.width, subviews: subviews)
        for (subview, slot) in zip(subviews, geometry.slots) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: slot.width, height: slot.height)
            )
        }
    }

    private func geometry(width: CGFloat?, subviews: Subviews) -> DetailColumnsGeometry {
        DetailColumnsGeometry(
            placements: subviews.map { $0[DetailPlacementKey.self] }, width: width, columns: columns, spacing: spacing, sideWidth: sideWidth,
            equalHeights: equalHeights
        ) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}

/// A sheet's scrolling content, told how many columns its own width allows: the width of the sheet's column, not the
/// window's, so hiding the sidebar or widening the list of builds counts too.
struct DetailScroll<Content: View>: View {
    var spacing: CGFloat = 18
    var sideWidth: CGFloat? = DetailColumns.sideWidth
    var equalHeights = false
    @ViewBuilder var content: (DetailColumns) -> Content
    /// Only the mode is kept, not the width: resizing redraws the sheet when the threshold is crossed, not at every point.
    @State private var columns = DetailColumns.one

    var body: some View {
        ScrollView {
            DetailColumnsLayout(columns: columns, spacing: spacing, sideWidth: sideWidth, equalHeights: equalHeights) {
                content(columns)
            }
            .padding(DetailColumns.margin)
        }
        .onGeometryChange(for: DetailColumns.self) { DetailColumns(width: $0.size.width) } action: { columns = $0 }
    }
}

/// The same groups on one or two columns, for a block inside a page that scrolls by itself: it measures its own width.
struct DetailColumnsBlock<Content: View>: View {
    var spacing: CGFloat = 18
    var sideWidth: CGFloat? = DetailColumns.sideWidth
    var equalHeights = false
    @ViewBuilder var content: (DetailColumns) -> Content
    @State private var columns = DetailColumns.one

    var body: some View {
        DetailColumnsLayout(columns: columns, spacing: spacing, sideWidth: sideWidth, equalHeights: equalHeights) {
            content(columns)
        }
        // A sheet's threshold counts its margins; this block has none of its own.
        .onGeometryChange(for: DetailColumns.self) { DetailColumns(width: $0.size.width + 2 * DetailColumns.margin) } action: { columns = $0 }
    }
}
