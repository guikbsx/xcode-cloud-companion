import SwiftUI

/// Sizes of a ring: the stroke grows with the ring, but more slowly than it.
nonisolated enum BuildRingMetrics {
    private static let widths: [(size: CGFloat, line: CGFloat)] = [(16, 2.5), (26, 3.5), (36, 4.5), (40, 5), (56, 6), (96, 10), (160, 14)]
    /// Between two concentric rings.
    static let concentricGap: CGFloat = 3
    static let selectedScale: CGFloat = 1.14
    /// Below this size a cross, a slit or a count cannot be read: only the arcs and the head are left.
    static let smallestWithMarkers: CGFloat = 24
    /// Most rings in one set.
    static let mostConcentric = 3

    static func lineWidth(for size: CGFloat) -> CGFloat {
        guard let first = widths.first, let last = widths.last else { return size / 10 }
        if size <= first.size { return size * first.line / first.size }
        if size >= last.size { return size * last.line / last.size }
        for (low, high) in zip(widths, widths.dropFirst()) where size <= high.size {
            return low.line + (high.line - low.line) * (size - low.size) / (high.size - low.size)
        }
        return last.line
    }

    /// The radius of the middle of the stroke of ring number `index`, the outer one being 0.
    static func radius(size: CGFloat, lineWidth: CGFloat, index: Int) -> CGFloat {
        max(lineWidth / 2, size / 2 - lineWidth / 2 - CGFloat(index) * (lineWidth + concentricGap))
    }
}

/// A ring ready to be drawn, with the colours already resolved: the painter is `nonisolated` and reads nothing of the main actor.
nonisolated struct BuildRingPainter: Sendable {
    struct Arc: Sendable {
        let start: Double
        let length: Double
        let solidLength: Double
        let isEstimated: Bool
        let marker: BuildRing.Marker
        let tint: Color
        let isRunning: Bool
    }

    let state: BuildRing.State
    let arcs: [Arc]
    let statusTint: Color
    let runningTint: Color
    let dashColor: Color
    /// The groove behind the arcs.
    let track: Color
    let overflow: Double?
    let paleTint: Color?
    /// Non-nil in a skeleton: the one grey every shape takes.
    let skeleton: Color?
    let drawsMarkers: Bool
    /// The running arc is drawn by a view that turns, not here.
    let spins: Bool
    let radius: CGFloat
    let lineWidth: CGFloat

    static let spinnerLength = 0.28

    // MARK: Drawing

    func draw(_ context: inout GraphicsContext, center: CGPoint) {
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        let scheme = context.environment.colorScheme
        if let skeleton {
            context.stroke(circle, with: .color(skeleton), lineWidth: lineWidth)
            return
        }
        switch state {
        case .skipped:
            context.stroke(circle, with: .color(statusTint.opacity(0.34)), lineWidth: lineWidth)
        case .unknown:
            if spins {
                context.stroke(circle, with: .color(runningTint.opacity(0.22)), lineWidth: lineWidth)
            } else {
                context.stroke(circle, with: shading(statusTint, center: center, scheme: scheme), lineWidth: lineWidth)
            }
        case .queued:
            if let paleTint { context.stroke(circle, with: .color(paleTint.opacity(0.16)), lineWidth: lineWidth) }
            dots(&context, from: 0, to: 1, width: min(2.4, max(1.2, lineWidth * 0.4)), spacing: min(6.3, max(3.6, lineWidth)), center: center)
        case .finished, .running, .overrun, .unestimated:
            context.drawLayer { layer in drawRing(&layer, circle: circle, center: center, scheme: scheme) }
        }
    }

    /// The turning arc of a ring with no end to reach, from the top.
    func drawSpinner(_ context: inout GraphicsContext, center: CGPoint) {
        let scheme = context.environment.colorScheme
        guard let path = capped(0, Self.spinnerLength, width: lineWidth, center: center) else { return }
        let paint = shading(runningTint, center: center, scheme: scheme)
        strokeArc(&context, path, paint, width: lineWidth)
    }

    private func drawRing(_ layer: inout GraphicsContext, circle: Path, center: CGPoint, scheme: ColorScheme) {
        layer.stroke(circle, with: .color(track), lineWidth: lineWidth)

        for arc in arcs where arc.isEstimated {
            guard let path = capped(arc.start, arc.start + arc.length, width: lineWidth, center: center) else { continue }
            layer.stroke(path, with: .color((paleTint ?? arc.tint).opacity(0.22)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }

        for arc in arcs where arc.marker == .dashed {
            dots(&layer, from: arc.start, to: arc.start + arc.length, width: min(2.2, max(1.1, lineWidth / 3)), spacing: min(6.2, max(3, lineWidth * 0.7)), center: center)
        }

        for arc in arcs where arc.solidLength > 1e-9 && !(spins && state == .unestimated && arc.isRunning) {
            guard let path = capped(arc.start, arc.start + arc.solidLength, width: lineWidth, center: center) else { continue }
            strokeArc(&layer, path, shading(arc.tint, center: center, scheme: scheme), width: lineWidth)
        }

        if drawsMarkers { cutMarkers(&layer, center: center) }

        if state == .overrun, let overflow, overflow > 0 {
            let thin = lineWidth * 0.5
            if let cut = capped(0, overflow, width: lineWidth * 0.77, center: center) {
                layer.blendMode = .clear
                layer.stroke(cut, with: .color(.black), style: StrokeStyle(lineWidth: lineWidth * 0.77, lineCap: .round))
                layer.blendMode = .normal
            }
            if let lap = capped(0, overflow, width: thin, center: center) {
                let deeper = Gradient(colors: [
                    runningTint.mix(with: .black, by: 0.45), runningTint.mix(with: .black, by: scheme == .dark ? 0.0 : 0.12),
                ])
                strokeArc(&layer, lap, gradientShading(deeper, center: center), width: thin)
            }
        }
    }

    /// A cross is cut out of a failed arc and a slit out of an errored one, so that the colour is not all that says it.
    private func cutMarkers(_ layer: inout GraphicsContext, center: CGPoint) {
        let cutter = StrokeStyle(lineWidth: lineWidth * 0.3, lineCap: .round)
        let circumference = 2 * Double.pi * Double(radius)
        for arc in arcs where arc.marker == .cross || arc.marker == .slit {
            guard arc.solidLength >= arc.length * 0.9, arc.length * circumference > Double(lineWidth) * 1.6 else { continue }
            let angle = (arc.start + arc.length / 2) * 2 * .pi
            let direction = CGVector(dx: sin(angle), dy: -cos(angle))
            let point = CGPoint(x: center.x + radius * direction.dx, y: center.y + radius * direction.dy)
            var path = Path()
            if arc.marker == .cross {
                let half = lineWidth * 0.33
                path.move(to: CGPoint(x: point.x - half, y: point.y - half))
                path.addLine(to: CGPoint(x: point.x + half, y: point.y + half))
                path.move(to: CGPoint(x: point.x + half, y: point.y - half))
                path.addLine(to: CGPoint(x: point.x - half, y: point.y + half))
            } else {
                let reach = lineWidth * 0.58
                path.move(to: CGPoint(x: point.x - reach * direction.dx, y: point.y - reach * direction.dy))
                path.addLine(to: CGPoint(x: point.x + reach * direction.dx, y: point.y + reach * direction.dy))
            }
            layer.blendMode = .clear
            layer.stroke(path, with: .color(.black), style: cutter)
            layer.blendMode = .normal
        }
    }

    // MARK: Pieces

    /// The visible span from `start` to `end` (turns), the round ends taken out of it: they are added by the stroke.
    private func capped(_ start: Double, _ end: Double, width: CGFloat, center: CGPoint) -> Path? {
        guard end > start else { return nil }
        let capTurns = Double(width) / (2 * Double.pi * Double(radius))
        var from = start + capTurns / 2
        var to = end - capTurns / 2
        if to <= from {
            let middle = (start + end) / 2
            from = middle
            to = middle + 1e-4
        }
        return arc(from, to, center: center)
    }

    private func arc(_ from: Double, _ to: Double, center: CGPoint) -> Path {
        if to - from >= 1 - 1e-6 {
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        return Path { path in
            path.addArc(center: center, radius: radius, startAngle: .degrees(from * 360 - 90), endAngle: .degrees(to * 360 - 90), clockwise: false)
        }
    }

    private func dots(_ context: inout GraphicsContext, from: Double, to: Double, width: CGFloat, spacing: CGFloat, center: CGPoint) {
        let length = (to - from) * 2 * Double.pi * Double(radius)
        guard length > 0 else { return }
        let count = max(1, Int((length / Double(spacing)).rounded()))
        let period = length / Double(count)
        context.stroke(
            arc(from, to, center: center), with: .color(dashColor),
            style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.001, CGFloat(period)])
        )
    }

    private func strokeArc(_ context: inout GraphicsContext, _ path: Path, _ paint: GraphicsContext.Shading, width: CGFloat) {
        context.stroke(path, with: paint, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func shading(_ tint: Color, center: CGPoint, scheme: ColorScheme) -> GraphicsContext.Shading {
        gradientShading(
            Gradient(colors: [tint.mix(with: .black, by: scheme == .dark ? 0 : 0.14), tint.mix(with: .white, by: 0.45)]),
            center: center
        )
    }

    private func gradientShading(_ gradient: Gradient, center: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(
            gradient, startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
            endPoint: CGPoint(x: center.x + radius, y: center.y - radius + 0.7 * radius)
        )
    }
}

// MARK: - View

/// What sits in the middle of a ring.
enum BuildRingCenter {
    case none
    /// The app's icon cut to a circle, or without one a disc in the app's colour with its initial.
    case app(AppSwatch, initial: String, artwork: AppArtwork? = nil)
    case text(String, detail: String? = nil)
}

/// The ring of a build: one arc per action, from the top and clockwise. Breathes and turns only with the system's motion on;
/// the arcs are drawn from a `BuildRing` worked out by the caller (see `BuildRingsClock` to have it follow the clock).
struct BuildRingView: View {
    let ring: BuildRing
    let size: CGFloat
    var lineWidth: CGFloat?
    var center: BuildRingCenter = .none
    var isSelected = false
    /// The colour of the part still to come; the colour of its state when nil.
    var paleTint: Color?

    var body: some View {
        BuildRingStack(
            rings: [.init(ring: ring, paleTint: paleTint)], size: size, lineWidth: lineWidth, center: center, isSelected: isSelected,
            showsBadge: true
        )
    }
}

/// Two or three builds as nested rings, the earliest to finish on the outside, tracks of the same thickness three points apart.
struct ConcentricBuildRingsView: View {
    struct Item {
        let ring: BuildRing
        /// The colour of the part still to come, usually the colour of the app.
        var paleTint: Color?

        init(ring: BuildRing, paleTint: Color? = nil) {
            self.ring = ring
            self.paleTint = paleTint
        }
    }

    let items: [Item]
    let size: CGFloat
    var lineWidth: CGFloat?
    var center: BuildRingCenter = .none

    var body: some View {
        BuildRingStack(
            rings: Array(items.prefix(BuildRingMetrics.mostConcentric)), size: size, lineWidth: lineWidth, center: center,
            isSelected: false, showsBadge: false
        )
    }
}

private struct BuildRingStack: View {
    let rings: [ConcentricBuildRingsView.Item]
    let size: CGFloat
    let lineWidth: CGFloat?
    let center: BuildRingCenter
    let isSelected: Bool
    let showsBadge: Bool

    @Environment(\.redactionReasons) private var redaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.backgroundProminence) private var prominence
    @State private var headDimmed = false
    @State private var queueDimmed = false
    @State private var turn = 0.0

    private struct Motion: Equatable {
        var head = false
        var queued = false
        var spins = false
    }

    private var width: CGFloat { lineWidth ?? BuildRingMetrics.lineWidth(for: size) }
    private var isSkeleton: Bool { redaction.isSkeleton }
    /// On the accent of a chosen row the colours would drown in the blue: the arcs turn white, as a system glyph does, and the
    /// crosses, slits and dots keep saying the state.
    private var onAccent: Bool { prominence == .increased }
    private var movesFreely: Bool { !reduceMotion && !isSkeleton }
    private var padding: CGFloat { width * 2 + 2 }
    private var boxSize: CGFloat { size + 2 * padding }

    private func spins(_ ring: BuildRing) -> Bool {
        movesFreely && (ring.state == .unestimated || (ring.state == .unknown && ring.status == .running))
    }

    private var motion: Motion {
        guard movesFreely else { return Motion() }
        return Motion(
            head: rings.contains { $0.ring.head != nil || spins($0.ring) },
            queued: rings.contains { $0.ring.state == .queued },
            spins: rings.contains { spins($0.ring) }
        )
    }

    var body: some View {
        ZStack {
            if isSelected, !isSkeleton { selection }
            ZStack {
                painted
                ForEach(rings.indices, id: \.self) { index in marks(of: rings[index].ring, index: index) }
                badges
                centerContent
            }
            .scaleEffect(isSelected ? BuildRingMetrics.selectedScale : 1)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: rings.map(\.ring.spokenDescription).joined(separator: "; ")))
        .onChange(of: motion, initial: true) { _, motion in animate(motion) }
    }

    // MARK: Drawing

    private var painted: some View {
        let painters = rings.indices.map { painter(for: $0) }
        return ZStack {
            canvas(painters.filter { $0.state != .queued })
            canvas(painters.filter { $0.state == .queued }).opacity(queueDimmed ? 0.35 : 1)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func canvas(_ painters: [BuildRingPainter]) -> some View {
        Canvas { context, canvasSize in
            let middle = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for painter in painters { painter.draw(&context, center: middle) }
        }
        .frame(width: boxSize, height: boxSize)
        .frame(width: size, height: size)
    }

    private func painter(for index: Int) -> BuildRingPainter {
        let item = rings[index]
        let ink: Color? = onAccent ? .white : nil
        let arcs = item.ring.arcs.map { arc in
            BuildRingPainter.Arc(
                start: arc.start, length: arc.length, solidLength: arc.solidLength, isEstimated: arc.isEstimated,
                marker: arc.marker, tint: ink ?? arc.status.tint, isRunning: arc.status == .running
            )
        }
        return BuildRingPainter(
            state: item.ring.state, arcs: arcs, statusTint: ink ?? item.ring.status.tint, runningTint: ink ?? BuildStatus.running.tint,
            dashColor: ink?.opacity(0.75) ?? Color(nsColor: .systemGray),
            track: ink?.opacity(0.28) ?? Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.08), overflow: item.ring.overflow,
            paleTint: ink ?? item.paleTint,
            skeleton: isSkeleton ? Color.skeleton : nil, drawsMarkers: size >= BuildRingMetrics.smallestWithMarkers,
            spins: spins(item.ring), radius: BuildRingMetrics.radius(size: size, lineWidth: width, index: index), lineWidth: width
        )
    }

    // MARK: Head

    @ViewBuilder
    private func marks(of ring: BuildRing, index: Int) -> some View {
        let radius = BuildRingMetrics.radius(size: size, lineWidth: width, index: index)
        if isSkeleton {
            EmptyView()
        } else if spins(ring) {
            let painter = painter(for: index)
            ZStack {
                Canvas { context, canvasSize in
                    painter.drawSpinner(&context, center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
                }
                .frame(width: boxSize, height: boxSize)
                headMark(tint: BuildStatus.running.tint, at: BuildRingPainter.spinnerLength, radius: radius, thin: false)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turn))
            .allowsHitTesting(false)
        } else if let head = headPosition(of: ring) {
            headMark(tint: ring.state == .overrun ? BuildStatus.running.tint.mix(with: .black, by: 0.1) : BuildStatus.running.tint, at: head, radius: radius, thin: ring.state == .overrun)
                .frame(width: size, height: size)
        }
    }

    private func headPosition(of ring: BuildRing) -> Double? {
        ring.state == .overrun ? ring.overflow : ring.head
    }

    private func headMark(tint: Color, at turns: Double, radius: CGFloat, thin: Bool) -> some View {
        let scale: CGFloat = thin ? 0.86 : 1
        let angle = turns * 2 * .pi
        return RingHeadMark(tint: tint, haloRadius: (width * 0.8 + 1.8) * scale, dotRadius: (width * 0.14 + 2) * scale, isDimmed: headDimmed)
            .offset(x: radius * CGFloat(sin(angle)), y: -radius * CGFloat(cos(angle)))
    }

    // MARK: Badge

    @ViewBuilder
    private var badges: some View {
        if showsBadge, !isSkeleton, width >= 5, let ring = rings.first?.ring {
            let radius = BuildRingMetrics.radius(size: size, lineWidth: width, index: 0) + width * 1.5
            ForEach(Array(ring.arcs.enumerated()).filter { $0.element.mergedCount > 1 }, id: \.offset) { _, arc in
                let angle = (arc.start + arc.length / 2) * 2 * .pi
                Text(verbatim: String(arc.mergedCount))
                    .font(.system(size: width * 1.17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: width * 1.92, height: width * 1.92)
                    .background(Color(nsColor: .systemGray).mix(with: .black, by: 0.3), in: .circle)
                    .offset(x: radius * CGFloat(sin(angle)), y: -radius * CGFloat(cos(angle)))
            }
        }
    }

    // MARK: Centre

    private var innerRadius: CGFloat {
        BuildRingMetrics.radius(size: size, lineWidth: width, index: rings.count - 1) - width / 2
    }

    @ViewBuilder
    private var centerContent: some View {
        switch center {
        case .none:
            EmptyView()
        case .app(let swatch, let initial, let artwork):
            let diameter = max(0, 2 * (BuildRingMetrics.radius(size: size, lineWidth: width, index: 0) - width / 2 - max(2.5, width * 0.6)))
            if isSkeleton {
                Circle().fill(Color.skeleton).frame(width: diameter, height: diameter)
            } else if rings.first?.ring.state == .skipped {
                Circle().fill(Color.primary.opacity(0.1)).frame(width: diameter, height: diameter)
                    .overlay(Capsule().fill(.secondary).frame(width: diameter * 0.34, height: max(1, diameter * 0.07)))
            } else {
                AppRoundIcon(name: initial, swatch: swatch, artwork: artwork, diameter: diameter)
            }
        case .text(let main, let detail):
            let diameter = max(0, 2 * (innerRadius - width * 0.4))
            VStack(spacing: diameter * 0.04) {
                Text(verbatim: main)
                    .font(.system(size: diameter * (main.count <= 2 ? 0.6 : main.count <= 4 ? 0.36 : 0.27), weight: .bold).monospacedDigit())
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: max(9, diameter * 0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(width: diameter, height: diameter)
        }
    }

    // MARK: Selection

    private var selection: some View {
        let accent = colorScheme == .dark ? CumulusStyle.accent.mix(with: .white, by: 0.2) : CumulusStyle.accent
        let outer = BuildRingMetrics.radius(size: size, lineWidth: width, index: 0) + width / 2 + width * 0.67
        return Circle().strokeBorder(accent, lineWidth: 1.4).frame(width: outer * 2, height: outer * 2)
            .scaleEffect(BuildRingMetrics.selectedScale)
        .allowsHitTesting(false)
    }

    // MARK: Motion

    private func animate(_ motion: Motion) {
        repeating(motion.head, 1.8) { headDimmed = $0 }
        repeating(motion.queued, 2.0) { queueDimmed = $0 }
        if motion.spins {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { turn = 360 }
        } else {
            withTransaction(Transaction(animation: nil)) { turn = 0 }
        }
    }

    private func repeating(_ on: Bool, _ seconds: Double, _ set: (Bool) -> Void) {
        if on {
            withAnimation(.easeInOut(duration: seconds).repeatForever(autoreverses: true)) { set(true) }
        } else {
            withTransaction(Transaction(animation: nil)) { set(false) }
        }
    }
}

/// The present moment of a running build: a white point edged with the colour of the build.
private struct RingHeadMark: View {
    let tint: Color
    let haloRadius: CGFloat
    let dotRadius: CGFloat
    let isDimmed: Bool

    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: max(1, dotRadius * 0.35)))
            .frame(width: dotRadius * 2, height: dotRadius * 2)
            .opacity(isDimmed ? 0.45 : 1)
            .frame(width: haloRadius * 2, height: haloRadius * 2)
    }
}

// MARK: - Following the clock

/// Works out the rings of some builds for the present moment, and again when one of them next looks different (a minute at
/// most), not at every frame. The time is view state set by a task of the main actor, as in `TickingView`.
struct BuildRingsClock<Content: View>: View {
    let runs: [CIBuildRun]
    let snapshot: BuildSnapshot
    @ViewBuilder let content: ([BuildRing]) -> Content
    @State private var now = Date()

    var body: some View {
        content(runs.map { BuildRing(run: $0, in: snapshot, now: now) })
            .task(id: runs.map { "\($0.id)\($0.executionProgress)" }) {
                while !Task.isCancelled {
                    now = Date()
                    let rings = runs.map { BuildRing(run: $0, in: snapshot, now: now) }
                    guard let next = rings.compactMap(\.nextChange).min() else { return }
                    try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                }
            }
    }
}

#Preview("Ring") {
    let now = Date()
    let started = now.addingTimeInterval(-400)
    let run = CIBuildRun(
        id: "r", productID: "p", number: 7, createdDate: started, startedDate: started, finishedDate: now, executionProgress: .complete,
        completionStatus: .failed, startReason: nil, workflowID: "wf", workflowName: "Release", sourceBranchOrTag: "main"
    )
    let actions = [
        CIBuildAction(
            id: "a", buildRunID: "r", name: "Build", actionType: .build, startedDate: started, finishedDate: started.addingTimeInterval(120),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: nil
        ),
        CIBuildAction(
            id: "b", buildRunID: "r", name: "Test", actionType: .test, startedDate: started.addingTimeInterval(120),
            finishedDate: started.addingTimeInterval(340), executionProgress: .complete, completionStatus: .failed, isRequiredToPass: nil
        ),
    ]
    let ring = BuildRing(run: run, in: BuildSnapshot(runs: [run], actionsByRunID: ["r": actions]), now: now)
    return HStack(spacing: 24) {
        BuildRingView(ring: ring, size: 26, center: .app(.blue, initial: "C"))
        BuildRingView(ring: ring, size: 96, center: .text("9 min", detail: "ends 14:49"))
        BuildRingView(ring: ring, size: 56, center: .app(.purple, initial: "H"), isSelected: true)
    }
    .padding(30)
}
