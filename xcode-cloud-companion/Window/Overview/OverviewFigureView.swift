import SwiftUI

/// The colours of the mosaic. System colours, so the squares follow light, dark and increased contrast.
enum OverviewColors {
    /// How much of its colour a square takes for one build, two, three, four and more; the rest is the window behind it.
    static let strengths: [Double] = [0.34, 0.56, 0.78, 1]

    static var succeeded: Color { BuildStatus.succeeded.tint }
    static var failed: Color { BuildStatus.failed.tint }
    static var mixed: Color { BuildStatus.errored.tint }
    static var running: Color { BuildStatus.running.tint }
    static var empty: Color { Color.primary.opacity(0.1) }
    static var rule: Color { Color.primary.opacity(0.12) }

    static func square(for cell: OverviewMosaic.Cell) -> Color {
        let base: Color
        switch cell.outcome {
        case .none: return empty
        case .succeeded: base = succeeded
        case .failed: base = failed
        case .mixed: base = mixed
        }
        return base.opacity(strengths[min(max(cell.intensity, 1), strengths.count) - 1])
    }

    /// Words in the colour of a state, drawn towards the text's own so they stay readable on a light window.
    static func ink(_ tone: OverviewHeadline.Tone) -> Color {
        switch tone {
        case .alert: BuildStatus.failed.textTint
        case .warning: BuildStatus.errored.textTint
        case .active: BuildStatus.running.textTint
        case .good: BuildStatus.succeeded.textTint
        case .neutral: .secondary
        }
    }
}

/// The figure of the Overview: the day-by-day outcome of every workflow, one row each, with the figures of the last seven
/// days at the end of the row. Drawn from `OverviewMosaic` at the size `layout` says.
struct OverviewFigureView: View {
    let mosaic: OverviewMosaic
    let layout: OverviewFigureLayout
    /// The outline round the run of failures of a broken workflow, in the colour of the headline's emphasis.
    let seriesColor: Color
    /// The minutes of the cycle at the end of the rows are computed, not billed: the column says so.
    var cycleIsEstimated = true
    var calendar = Calendar.current
    var locale = Locale.autoupdatingCurrent
    var artwork: [String: AppArtwork] = [:]
    var now: Date
    var openWorkflow: (String) -> Void = { _ in }
    var openApp: (String) -> Void = { _ in }
    var openBuild: (String) -> Void = { _ in }
    /// “See the day”: the builds of one workflow on one day, listed.
    var showDay: (String, Date) -> Void = { _, _ in }
    /// What the bubble of a square and the drawer of a workflow read; nil leaves both out.
    var details: OverviewDetailSource?
    /// What is open on the figure; the figure keeps its own unless a host (a test) gives one.
    var interaction: OverviewFigureInteraction?

    @State private var cursor: Cursor?
    @State private var ownInteraction = OverviewFigureInteraction()
    @FocusState private var isFocused: Bool
    @Environment(\.redactionReasons) private var redaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Spot = OverviewFigureInteraction.Spot
    private var state: OverviewFigureInteraction { interaction ?? ownInteraction }

    /// The square the keyboard is on.
    struct Cursor: Equatable {
        var row: Int
        var column: Int
    }

    /// How much of their colour the squares keep while a bubble speaks of another.
    static let dimmedOpacity = 0.62

    private var visibleDays: [Date] { Array(mosaic.days.suffix(layout.days)) }
    private var rows: [OverviewMosaic.Row] { mosaic.rows }

    var body: some View {
        let flat = rows
        VStack(alignment: .leading, spacing: 0) {
            header
            rowsStack(flat)
                .zIndex(1)
            bracket
        }
        .frame(width: layout.figureWidth, alignment: .leading)
        .background(alignment: .topLeading) { weekRules }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press, rows: flat) }
        .onChange(of: isFocused) { _, focused in
            if focused, cursor == nil, !flat.isEmpty { cursor = Cursor(row: flat.count - 1, column: layout.days - 1) }
        }
        .onChange(of: layout.days) { state.reset() }
        .onHover { inside in
            if inside { state.pointerEnteredFigure() } else { state.pointerLeftFigure() }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: layout.nameWidth + OverviewFigureLayout.nameGap, height: 1)
            headerDays
                .frame(width: layout.cellsWidth, height: Self.headerHeight)
            Color.clear.frame(width: OverviewFigureLayout.figuresGap, height: 1)
            figureHeads
        }
        .frame(height: Self.headerHeight, alignment: .top)
        .accessibilityHidden(true)
    }

    static let headerHeight: CGFloat = 32

    private var headerDays: some View {
        let words = OverviewScreenWords(locale: locale, calendar: calendar)
        let days = visibleDays
        let pitch = layout.pitch
        let side = layout.cellSide
        let skeleton = redaction.isSkeleton
        let todayIndex = days.count - 1
        return Canvas { context, size in
            let secondary = Color.secondary
            var lastLabelEnd = -CGFloat.infinity
            let todayText = context.resolve(Text("Today").font(.system(size: 10, weight: .bold)).foregroundStyle(.primary))
            let todayWidth = todayText.measure(in: size).width
            for (index, day) in days.enumerated() {
                let x = CGFloat(index) * pitch
                if !skeleton {
                    let isWeekend = calendar.isDateInWeekend(day)
                    let isToday = index == todayIndex
                    let initial = context.resolve(
                        Text(words.weekdayInitial(day)).font(.system(size: 9, weight: isToday ? .bold : .medium)).foregroundStyle(isToday ? Color.primary : secondary)
                    )
                    context.opacity = isWeekend && !isToday ? 0.55 : 1
                    context.draw(initial, at: CGPoint(x: x + side / 2, y: 27), anchor: .center)
                    context.opacity = 1
                }
                if !skeleton, calendar.component(.weekday, from: day) == calendar.firstWeekday {
                    let label = context.resolve(Text(words.weekStart(day)).font(.system(size: 10, weight: .semibold)).foregroundStyle(secondary))
                    let width = label.measure(in: size).width
                    let end = x + 2 + width
                    if end + 6 < size.width - todayWidth, x + 2 > lastLabelEnd {
                        context.draw(label, at: CGPoint(x: x + 2, y: 10), anchor: .leading)
                        lastLabelEnd = end
                    }
                }
            }
            if !skeleton {
                context.draw(todayText, at: CGPoint(x: size.width + 2, y: 10), anchor: .trailing)
            }
        }
    }

    private var figureHeads: some View {
        HStack(alignment: .top, spacing: OverviewFigureLayout.columnGap) {
            head("Success\n7 d", width: OverviewFigureLayout.successWidth)
            head("Median\nduration", width: OverviewFigureLayout.medianWidth)
            if layout.showsCycle {
                if cycleIsEstimated {
                    head("Cycle\nestimated", width: OverviewFigureLayout.cycleWidth)
                } else {
                    head("Cycle", width: OverviewFigureLayout.cycleWidth)
                }
            }
        }
        .frame(width: layout.figuresWidth, alignment: .leading)
        .unredacted()
    }

    private func head(_ title: LocalizedStringKey, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .frame(width: width, alignment: .trailing)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Rows

    private func rowsStack(_ flat: [OverviewMosaic.Row]) -> some View {
        let lit = state.litSpot
        let drawerRowID = state.drawer?.rowID
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mosaic.groups.enumerated()), id: \.element.id) { groupIndex, group in
                groupHeader(group)
                    .padding(.top, groupIndex == 0 ? 0 : 5)
                ForEach(group.rows) { row in
                    let position = flat.firstIndex(where: { $0.id == row.id }) ?? 0
                    OverviewMosaicRow(
                        app: group.name, row: row, layout: layout, days: visibleDays, calendar: calendar, locale: locale, now: now,
                        seriesColor: seriesColor, focusedColumn: isFocused && cursor?.row == position ? cursor?.column : nil,
                        lit: lit, bubble: popoverBinding(for: row, group: group), drawsBubbleInline: !state.presentsPopover, openBubble: state.bubble.flatMap { $0.spot.rowID == row.id ? $0 : nil }, drawerIsOpen: drawerRowID == row.id,
                        drawerIsAvailable: details != nil, swatch: group.swatch, artwork: artwork[group.productID],
                        openWorkflow: openWorkflow,
                        select: { column in
                            cursor = Cursor(row: position, column: column)
                            isFocused = true
                            state.openBubble(bubble(for: row, group: group, column: column))
                        },
                        hover: { column in
                            guard let column else { return state.pointerLeftSquares() }
                            state.pointerEntered(Spot(rowID: row.id, column: column)) { bubble(for: row, group: group, column: column) }
                        },
                        hoverName: { inside in
                            if inside {
                                state.pointerEnteredName(row.id) { drawer(for: row) }
                            } else {
                                state.pointerLeftName()
                            }
                        },
                        toggleDrawer: { state.toggleDrawer(row.id) { drawer(for: row) } },
                        openBubbleBuild: { id in
                            state.closeBubble()
                            openBuild(id)
                        },
                        showDay: { column in
                            state.closeBubble()
                            if let cell = cell(of: row, column: column) { showDay(row.workflowID, cell.day) }
                        },
                        bubbleHover: { state.pointerInBubble($0) }
                    )
                    .zIndex(lit?.rowID == row.id ? 1 : 0)
                    if let drawer = state.drawer, drawer.rowID == row.id {
                        OverviewDurationDrawerView(series: drawer.series, layout: layout, calendar: calendar, locale: locale)
                            .padding(.top, OverviewDurationDrawerView.gap)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: drawerRowID)
        .background(alignment: .topLeading) { litColumn }
    }

    // MARK: Bubble and drawer

    private func bubble(for row: OverviewMosaic.Row, group: OverviewMosaic.Group, column: Int) -> OverviewFigureInteraction.Bubble? {
        guard let details, let cell = cell(of: row, column: column), let detail = details.dayDetail(row: row, appName: group.name, day: cell.day) else { return nil }
        return OverviewFigureInteraction.Bubble(spot: Spot(rowID: row.id, column: column), detail: detail, swatch: group.swatch, productID: group.productID)
    }

    private func drawer(for row: OverviewMosaic.Row) -> OverviewFigureInteraction.Drawer? {
        details.map { OverviewFigureInteraction.Drawer(rowID: row.id, series: $0.durationSeries(row: row)) }
    }

    private func popoverBinding(for row: OverviewMosaic.Row, group: OverviewMosaic.Group) -> Binding<OverviewFigureInteraction.Bubble?> {
        Binding(
            get: {
                guard state.presentsPopover, let bubble = state.bubble, bubble.spot.rowID == row.id else { return nil }
                return bubble
            },
            set: { value in
                if value == nil, let bubble = state.bubble, bubble.spot.rowID == row.id { state.bubbleWasDismissed(bubble.id) }
            }
        )
    }

    /// The stripe of the square the bubble speaks of, down every row.
    private var litColumn: some View {
        let spot = state.litSpot
        let left = layout.nameWidth + OverviewFigureLayout.nameGap
        let pitch = layout.pitch
        let side = layout.cellSide
        return Canvas { context, size in
            guard let spot else { return }
            let rect = CGRect(x: left + CGFloat(spot.column) * pitch - 2.5, y: -2, width: side + 5, height: size.height + 2)
            let shape = Path(roundedRect: rect, cornerRadius: 7)
            context.fill(shape, with: .color(CumulusStyle.accent.opacity(0.12)))
            context.stroke(shape, with: .color(CumulusStyle.accent.opacity(0.45)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func groupHeader(_ group: OverviewMosaic.Group) -> some View {
        HStack(spacing: 0) {
            Button {
                openApp(group.productID)
            } label: {
                HStack(spacing: 7) {
                    AppIconView(name: group.name, swatch: redaction.isSkeleton ? .gray : group.swatch, size: 16, artwork: artwork[group.productID])
                    Text(group.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                .frame(width: layout.nameWidth, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            Color.clear.frame(width: OverviewFigureLayout.nameGap, height: 1)
            Rectangle().fill(OverviewColors.rule).frame(height: 1)
        }
        .frame(height: 20)
    }

    private func cell(of row: OverviewMosaic.Row, column: Int) -> OverviewMosaic.Cell? {
        let cells = row.cells.suffix(layout.days)
        let offset = cells.startIndex + column
        return cells.indices.contains(offset) ? cells[offset] : nil
    }

    // MARK: Week rules and bracket

    /// A thin vertical line at the start of each week, behind the header and every row.
    private var weekRules: some View {
        let days = visibleDays
        let pitch = layout.pitch
        let left = layout.nameWidth + OverviewFigureLayout.nameGap
        let skeleton = redaction.isSkeleton
        return Canvas { context, size in
            guard !skeleton else { return }
            for (index, day) in days.enumerated() where index > 0 && calendar.component(.weekday, from: day) == calendar.firstWeekday {
                let x = left + CGFloat(index) * pitch - 1.5
                var line = Path()
                line.move(to: CGPoint(x: x.rounded() + 0.5, y: 15))
                line.addLine(to: CGPoint(x: x.rounded() + 0.5, y: size.height - 19))
                context.stroke(line, with: .color(OverviewColors.rule), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Under the last seven columns, the ones the figures at the end of each row speak of.
    private var bracket: some View {
        let seven = min(OverviewMosaic.recentDays, layout.days)
        let left = layout.nameWidth + OverviewFigureLayout.nameGap + CGFloat(layout.days - seven) * layout.pitch
        let right = layout.nameWidth + OverviewFigureLayout.nameGap + layout.cellsWidth
        return Canvas { context, _ in
            var path = Path()
            path.move(to: CGPoint(x: left, y: 3))
            path.addLine(to: CGPoint(x: left, y: 7))
            path.addLine(to: CGPoint(x: right, y: 7))
            path.addLine(to: CGPoint(x: right, y: 3))
            context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: layout.figureWidth, height: 17)
        .opacity(redaction.isSkeleton ? 0 : 1)
        .accessibilityHidden(true)
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, rows: [OverviewMosaic.Row]) -> KeyPress.Result {
        if press.key == .escape {
            guard press.phase == .down else { return .handled }
            if state.bubble != nil {
                state.closeBubble()
                return .handled
            }
            if state.drawer != nil {
                state.closeDrawer()
                return .handled
            }
            return .ignored
        }
        guard !rows.isEmpty, var spot = cursor else { return .ignored }
        switch press.key {
        case .leftArrow: spot.column = max(0, spot.column - 1)
        case .rightArrow: spot.column = min(layout.days - 1, spot.column + 1)
        case .upArrow: spot.row = max(0, spot.row - 1)
        case .downArrow: spot.row = min(rows.count - 1, spot.row + 1)
        case .return, .space:
            guard press.phase == .down, rows.indices.contains(spot.row) else { return .handled }
            let row = rows[spot.row]
            if let group = mosaic.groups.first(where: { $0.rows.contains { $0.id == row.id } }) {
                state.openBubble(bubble(for: row, group: group, column: spot.column))
            }
            return .handled
        default:
            guard press.characters == "d", press.modifiers.isEmpty, press.phase == .down, rows.indices.contains(spot.row), details != nil else { return .ignored }
            let row = rows[spot.row]
            state.toggleDrawer(row.id) { drawer(for: row) }
            return .handled
        }
        cursor = spot
        return .handled
    }
}

/// One workflow's row: its name, a square for each day, and the figures of the last seven days.
private struct OverviewMosaicRow: View {
    let app: String
    let row: OverviewMosaic.Row
    let layout: OverviewFigureLayout
    let days: [Date]
    let calendar: Calendar
    let locale: Locale
    let now: Date
    let seriesColor: Color
    let focusedColumn: Int?
    /// The square the bubble speaks of, on any row: this row and its column are lit, the other squares pale.
    let lit: OverviewFigureInteraction.Spot?
    /// The popover of a square of this row.
    let bubble: Binding<OverviewFigureInteraction.Bubble?>
    /// The bubble is drawn under the square as a view, not presented as a popover (a test cannot capture a popover window).
    let drawsBubbleInline: Bool
    /// The bubble when it is on this row, whichever way it is shown.
    let openBubble: OverviewFigureInteraction.Bubble?
    let drawerIsOpen: Bool
    let drawerIsAvailable: Bool
    let swatch: AppSwatch
    let artwork: AppArtwork?
    let openWorkflow: (String) -> Void
    let select: (Int) -> Void
    /// The pointer is on a square (its column), or left the squares (nil).
    let hover: (Int?) -> Void
    let hoverName: (Bool) -> Void
    let toggleDrawer: () -> Void
    let openBubbleBuild: (String) -> Void
    let showDay: (Int) -> Void
    let bubbleHover: (Bool) -> Void
    @State private var isNameHovered = false
    @FocusState private var isDrawerButtonFocused: Bool
    @Environment(\.redactionReasons) private var redaction

    private var cells: [OverviewMosaic.Cell] { Array(row.cells.suffix(layout.days)) }
    private var isBroken: Bool { !row.isPaused && row.failureSeries != nil }
    private var isLitRow: Bool { lit?.rowID == row.id }
    private var isEmphasized: Bool { isBroken || drawerIsOpen }

    var body: some View {
        HStack(spacing: 0) {
            nameCell
            Color.clear.frame(width: OverviewFigureLayout.nameGap, height: 1)
            squares
            Color.clear.frame(width: OverviewFigureLayout.figuresGap, height: 1)
            figures
        }
        .frame(height: OverviewFigureLayout.rowHeight)
        .background(alignment: .leading) {
            if isLitRow, !redaction.isSkeleton {
                RoundedRectangle(cornerRadius: 7)
                    .fill(CumulusStyle.accent.opacity(0.08))
                    .padding(.horizontal, -6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(redaction.isSkeleton ? "" : OverviewScreenWords(locale: locale, calendar: calendar).rowSummary(app: app, row: row, now: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openWorkflow(row.workflowID) }
        .accessibilityAction(named: Text(drawerIsOpen ? "Hide durations" : "Show durations")) {
            if drawerIsAvailable { toggleDrawer() }
        }
    }

    /// The name opens the workflow; resting on it (or the small chevron, which the keyboard reaches) opens the
    /// drawer of its durations under the row.
    private var nameCell: some View {
        HStack(spacing: 0) {
            Button {
                openWorkflow(row.workflowID)
            } label: {
                Text(row.name)
                    .font(.system(size: isEmphasized ? 13 : 12, weight: isEmphasized ? .bold : .regular))
                    .foregroundStyle(row.isPaused ? .secondary : .primary)
                    .lineLimit(1)
                    .padding(.leading, 23)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the workflow")
            if drawerIsAvailable, !redaction.isSkeleton {
                Button(action: toggleDrawer) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(drawerIsOpen ? 180 : 0))
                        .frame(width: 18, height: OverviewFigureLayout.rowHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focused($isDrawerButtonFocused)
                .opacity(isNameHovered || drawerIsOpen || isDrawerButtonFocused ? 1 : 0)
                .help(drawerIsOpen ? "Hide durations" : "Show durations")
                .accessibilityLabel(drawerIsOpen ? "Hide durations" : "Show durations")
            }
        }
        .frame(width: layout.nameWidth, alignment: .leading)
        .contentShape(.rect)
        .onHover { inside in
            isNameHovered = inside
            if drawerIsAvailable { hoverName(inside) }
        }
    }

    // MARK: Squares

    private var squares: some View {
        let cells = cells
        let pitch = layout.pitch
        let side = layout.cellSide
        let top = (OverviewFigureLayout.rowHeight - side) / 2
        let skeleton = redaction.isSkeleton
        let seriesSpan = row.isPaused ? nil : seriesColumns(cells)
        let focused = focusedColumn
        let rows = OverviewFigureLayout.rowHeight
        let lit = lit
        let isLitRow = isLitRow
        return Canvas { context, _ in
            for (index, cell) in cells.enumerated() {
                let rect = CGRect(x: CGFloat(index) * pitch, y: top, width: side, height: side)
                let shape = Path(roundedRect: rect, cornerRadius: min(4, side / 4))
                let color: Color = skeleton ? (cell.builds > 0 ? Color.skeleton : Color.skeleton.opacity(0.5)) : OverviewColors.square(for: cell)
                // While a bubble is open, the squares that are neither on its row nor in its column pale a little.
                context.opacity = lit != nil && !isLitRow && lit?.column != index ? OverviewFigureView.dimmedOpacity : 1
                context.fill(shape, with: .color(color))
                context.opacity = 1
            }
            if let seriesSpan, !skeleton {
                let x = CGFloat(seriesSpan.lowerBound) * pitch - 2.5
                let width = CGFloat(seriesSpan.count) * pitch - OverviewFigureLayout.cellGap + 5
                let outline = Path(roundedRect: CGRect(x: x, y: top - 2.5, width: width, height: side + 5), cornerRadius: 6)
                context.stroke(outline, with: .color(seriesColor), lineWidth: 1.6)
            }
            if let focused, cells.indices.contains(focused) {
                let rect = CGRect(x: CGFloat(focused) * pitch - 2, y: (rows - side) / 2 - 2, width: side + 4, height: side + 4)
                context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(.accentColor), lineWidth: 2)
            }
        }
        .frame(width: layout.cellsWidth, height: OverviewFigureLayout.rowHeight)
        .overlay(alignment: .topLeading) { liveMarks(cells) }
        .contentShape(.rect)
        .gesture(
            SpatialTapGesture().onEnded { value in
                let column = Int(value.location.x / pitch)
                if cells.indices.contains(column) { select(column) }
            }
        )
        .overlay(alignment: .topLeading) { inlineBubble }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let column = Int(point.x / pitch)
                // The three points between two squares keep the one the pointer left.
                guard cells.indices.contains(column), point.x - CGFloat(column) * pitch <= side else { return }
                hover(column)
            case .ended:
                hover(nil)
            }
        }
        .popover(item: bubble, attachmentAnchor: bubbleAnchor, arrowEdge: .bottom) { bubble in
            OverviewDayBubbleView(
                detail: bubble.detail, swatch: swatch, artwork: artwork, words: OverviewDayWords(locale: locale, calendar: calendar),
                openBuild: openBubbleBuild, showDay: { showDay(bubble.spot.column) }, hoverChanged: bubbleHover
            )
        }
    }

    @ViewBuilder
    private var inlineBubble: some View {
        if drawsBubbleInline, let open = openBubble {
            let center = CGFloat(open.spot.column) * layout.pitch + layout.cellSide / 2
            let width = OverviewDayBubbleView.width
            let left = min(max(center - width / 2, -layout.nameWidth), layout.cellsWidth + 40 - width)
            OverviewBubbleChrome(arrowX: center - left) {
                OverviewDayBubbleView(
                    detail: open.detail, swatch: swatch, artwork: artwork, words: OverviewDayWords(locale: locale, calendar: calendar)
                )
            }
            .offset(x: left, y: OverviewFigureLayout.rowHeight / 2 + layout.cellSide / 2 + 5)
            .allowsHitTesting(false)
        }
    }

    /// The square the popover points at.
    private var bubbleAnchor: PopoverAttachmentAnchor {
        let column = CGFloat(bubble.wrappedValue?.spot.column ?? 0)
        let side = layout.cellSide
        return .rect(.rect(CGRect(x: column * layout.pitch, y: (OverviewFigureLayout.rowHeight - side) / 2, width: side, height: side)))
    }

    /// The dot of a running build and the ring of a queued one, on the square of the day they belong to.
    private func liveMarks(_ cells: [OverviewMosaic.Cell]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if cell.running > 0 || cell.queued > 0, !redaction.isSkeleton {
                    LiveMark(isQueued: cell.running == 0)
                        .position(x: CGFloat(index) * layout.pitch + layout.cellSide / 2, y: OverviewFigureLayout.rowHeight / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The columns from the first failure of the run to the newest finished build, cut to the days on screen.
    private func seriesColumns(_ cells: [OverviewMosaic.Cell]) -> Range<Int>? {
        guard let series = row.failureSeries, let last = cells.indices.last else { return nil }
        let firstDay = series.firstDay(calendar: calendar)
        let lastDay = series.lastDate.map { calendar.startOfDay(for: $0) }
        let first = firstDay.flatMap { day in cells.firstIndex { $0.day >= day } } ?? 0
        let end = lastDay.flatMap { day in cells.lastIndex { $0.day <= day } } ?? last
        guard first <= end else { return nil }
        return first..<(end + 1)
    }

    // MARK: Figures

    private var figures: some View {
        HStack(spacing: OverviewFigureLayout.columnGap) {
            success
                .frame(width: OverviewFigureLayout.successWidth, alignment: .trailing)
            median
                .frame(width: OverviewFigureLayout.medianWidth, alignment: .trailing)
            if layout.showsCycle {
                cycle
                    .frame(width: OverviewFigureLayout.cycleWidth, alignment: .trailing)
            }
        }
        .font(.system(size: drawerIsOpen ? 13 : 12, weight: drawerIsOpen ? .semibold : .regular, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: layout.figuresWidth, alignment: .leading)
    }

    @ViewBuilder
    private var success: some View {
        if let rate = row.successRate {
            let percent = OverviewHeadlineWords(locale: locale, calendar: calendar).percent(rate)
            if rate < 0.7 {
                Text(percent).fontWeight(.bold).foregroundStyle(BuildStatus.failed.textTint)
            } else if rate < 0.9 {
                Text(percent).fontWeight(.bold).foregroundStyle(BuildStatus.errored.textTint)
            } else {
                Text(percent).fontWeight(.medium)
            }
        } else {
            Text(verbatim: "–").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var median: some View {
        if let seconds = row.medianSeconds {
            HStack(spacing: 4) {
                Text(UsageFormat.minutes(seconds / 60, locale: locale))
                switch row.trend {
                case .up: Text(verbatim: "↑").fontWeight(.bold).foregroundStyle(BuildStatus.errored.textTint)
                case .down: Text(verbatim: "↓").fontWeight(.bold).foregroundStyle(BuildStatus.succeeded.textTint)
                case .stable: Text(verbatim: "→").fontWeight(.bold).foregroundStyle(.secondary)
                case .unknown: EmptyView()
                }
            }
        } else {
            Text(verbatim: "–").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cycle: some View {
        if let cycle = row.cycle {
            Text((cycle.isEstimated ? "~" : "") + UsageFormat.compactMinutes(cycle.minutes, locale: locale)).foregroundStyle(.secondary)
        }
    }
}

/// A running build breathes; a queued one is a ring. Still with “Reduce motion”.
private struct LiveMark: View {
    let isQueued: Bool
    @State private var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isQueued {
                Circle().strokeBorder(OverviewColors.running, lineWidth: 1.6).frame(width: 8, height: 8)
            } else {
                Circle().fill(OverviewColors.running).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
        .opacity(isDimmed ? 0.35 : 1)
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            if reduce || isQueued {
                withTransaction(Transaction(animation: nil)) { isDimmed = false }
            } else {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { isDimmed = true }
            }
        }
        .accessibilityHidden(true)
    }
}
