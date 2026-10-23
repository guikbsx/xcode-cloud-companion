import SwiftUI

/// The drawer under a workflow's row: its median time per day, on the same columns as the squares, and the level change
/// `WorkflowSlowdown` found, with the medians before and after. It only draws an `OverviewDurationSeries`.
struct OverviewDurationDrawerView: View {
    static let height: CGFloat = 71
    /// The room between the row and the drawer.
    static let gap: CGFloat = 4
    /// What the drawer adds to the height of the figure.
    static var addedHeight: CGFloat { height + gap }
    /// The curve lives in this band of the drawer; the labels have the rest.
    private static let bandTop: CGFloat = 40
    private static let bandBottom: CGFloat = 63

    let series: OverviewDurationSeries
    let layout: OverviewFigureLayout
    var calendar = Calendar.current
    var locale = Locale.autoupdatingCurrent

    private var words: OverviewDurationWords { OverviewDurationWords(locale: locale, calendar: calendar) }

    /// The points on screen, the oldest first.
    private var points: [OverviewDurationSeries.Point] { Array(series.points.suffix(layout.days)) }

    /// The column of the level change among the columns on screen: negative when it came before the first one.
    private var stepColumn: Int? {
        guard let step = series.step, let column = step.column else { return series.step == nil ? nil : -1 }
        return column - (series.points.count - layout.days)
    }

    var body: some View {
        HStack(alignment: .top, spacing: OverviewFigureLayout.nameGap) {
            Text(words.caption(days: layout.days))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(width: layout.nameWidth, alignment: .leading)
                .padding(.top, 34)
            plot
                .frame(width: layout.cellsWidth, height: Self.height)
        }
        .frame(width: layout.figureWidth, height: Self.height, alignment: .topLeading)
        .background(alignment: .center) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: 9).fill(CumulusStyle.accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 9).strokeBorder(OverviewColors.rule)
            }
            .padding(.horizontal, -6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.spoken(series))
    }

    @ViewBuilder
    private var plot: some View {
        if series.hasData {
            Canvas { context, size in draw(in: &context, size: size) }
        } else {
            Text("No successful build in this period")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let points = points
        let pitch = layout.pitch
        let side = layout.cellSide
        let step = series.step
        let stepColumn = stepColumn
        let afterInk = BuildStatus.errored.textTint
        let beforeInk = Color.secondary

        var values = points.compactMap(\.medianSeconds)
        if let step, stepColumn != nil { values += [step.medianBefore, step.medianAfter] }
        guard let low = values.min(), let high = values.max() else { return }
        func y(_ seconds: TimeInterval) -> CGFloat {
            guard high > low else { return (Self.bandTop + Self.bandBottom) / 2 }
            return Self.bandBottom - CGFloat((seconds - low) / (high - low)) * (Self.bandBottom - Self.bandTop)
        }
        func x(_ column: Int) -> CGFloat { CGFloat(column) * pitch + side / 2 }
        func ink(_ column: Int) -> Color { stepColumn.map { column >= $0 } == true ? afterInk : beforeInk }

        // The levels before and after the change, and the line that marks the build where it happened.
        if let step, let stepColumn {
            let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])
            let stepX = stepColumn >= 0 ? x(stepColumn) : 0
            var before = Path()
            before.move(to: CGPoint(x: 0, y: y(step.medianBefore)))
            before.addLine(to: CGPoint(x: stepX, y: y(step.medianBefore)))
            if stepColumn > 0 { context.stroke(before, with: .color(beforeInk.opacity(0.7)), style: dash) }
            var after = Path()
            after.move(to: CGPoint(x: stepX, y: y(step.medianAfter)))
            after.addLine(to: CGPoint(x: size.width, y: y(step.medianAfter)))
            context.stroke(after, with: .color(afterInk.opacity(0.8)), style: dash)
            if stepColumn >= 0 {
                var marker = Path()
                marker.move(to: CGPoint(x: stepX, y: 5))
                marker.addLine(to: CGPoint(x: stepX, y: 67))
                context.stroke(marker, with: .color(afterInk), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }

        // The curve, cut where a day has no successful build (a gap, never a zero), and a dot on each day.
        for column in points.indices.dropFirst() {
            guard let from = points[column - 1].medianSeconds, let to = points[column].medianSeconds else { continue }
            var segment = Path()
            segment.move(to: CGPoint(x: x(column - 1), y: y(from)))
            segment.addLine(to: CGPoint(x: x(column), y: y(to)))
            context.stroke(segment, with: .color(ink(column)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        for (column, point) in points.enumerated() {
            guard let seconds = point.medianSeconds else { continue }
            let center = CGPoint(x: x(column), y: y(seconds))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.3, y: center.y - 2.3, width: 4.6, height: 4.6)), with: .color(ink(column)))
        }

        guard let step, let stepColumn else { return }
        // The words: “Slowdown” and the rise at the step, the medians at the two ends.
        let ends = CGPoint(x: x(max(stepColumn, 0)), y: 0)
        let labelWidth: CGFloat = 150
        let onTheLeft = ends.x + 8 + labelWidth > size.width
        let anchorX = onTheLeft ? ends.x - 8 : ends.x + 8
        let anchor: UnitPoint = onTheLeft ? .trailing : .leading
        let title = String(localized: "Slowdown", comment: "Small title over the level change in the drawer of a workflow in the Overview").uppercased(with: locale)
        context.draw(
            context.resolve(Text(verbatim: title).font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(afterInk)),
            at: CGPoint(x: anchorX, y: 12), anchor: anchor
        )
        let rise = context.resolve(Text(words.increase(step)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary))
        let riseWidth = rise.measure(in: size).width
        let since = words.sinceLine(step).map { context.resolve(Text($0).font(.system(size: 11)).foregroundStyle(Color.secondary)) }
        let sinceWidth = since.map { $0.measure(in: size).width + 4 } ?? 0
        let total = riseWidth + sinceWidth
        let start = onTheLeft ? anchorX - total : anchorX
        context.draw(rise, at: CGPoint(x: start, y: 26), anchor: .leading)
        if let since { context.draw(since, at: CGPoint(x: start + riseWidth + 4, y: 26), anchor: .leading) }
        if stepColumn > 0 {
            context.draw(
                context.resolve(Text(words.beforeLine(step)).font(.system(size: 10, weight: .semibold)).foregroundStyle(beforeInk)),
                at: CGPoint(x: 2, y: y(step.medianBefore) - 4), anchor: .bottomLeading
            )
        }
        context.draw(
            context.resolve(Text(words.afterLine(step)).font(.system(size: 10, weight: .semibold)).foregroundStyle(afterInk)),
            at: CGPoint(x: size.width - 2, y: y(step.medianAfter) + 6), anchor: .topTrailing
        )
    }
}
