import AppKit

/// The ring that stands in for the cloud in the menu bar while a build runs: which build it is, and how it is drawn into the
/// image of the button.
nonisolated enum MenuBarRing {
    /// The ring itself; the image is a little larger so that the head is not cut.
    static let size: CGFloat = 16
    static let canvas: CGFloat = 18

    /// The ring of the build that ends first among every account's running and queued builds (the order of the menu); nil when
    /// none runs.
    static func leader(in snapshots: [BuildSnapshot], now: Date, locale: Locale = .autoupdatingCurrent) -> BuildRing? {
        var best: (entry: RunningBuildsETA.Entry, snapshot: BuildSnapshot)?
        for snapshot in snapshots {
            guard let first = RunningBuildsETA.entries(in: snapshot, now: now).first else { continue }
            if let current = best, !RunningBuildsETA.precedes(first, current.entry) { continue }
            best = (first, snapshot)
        }
        return best.map { BuildRing(run: $0.entry.run, in: $0.snapshot, now: now, locale: locale) }
    }

    #if DEBUG
    /// A build that is not there, for `XCC_BADGE=running`: two actions, the second one running and due to end in `minutes`.
    static func sample(minutes: Double, now: Date) -> BuildRing {
        let usual = 90 + minutes * 60
        func run(_ id: String, number: Int, started: Date, finished: Date?, progress: CIExecutionProgress, completion: CICompletionStatus?) -> CIBuildRun {
            CIBuildRun(
                id: id, productID: "debug", number: number, createdDate: started, startedDate: started, finishedDate: finished,
                executionProgress: progress, completionStatus: completion, startReason: nil, workflowID: "debug", workflowName: "Release",
                sourceBranchOrTag: "main"
            )
        }
        func action(_ run: String, _ name: String, _ type: CIActionType, start: Date, seconds: TimeInterval?, completion: CICompletionStatus?) -> CIBuildAction {
            CIBuildAction(
                id: "\(run)-\(name)", buildRunID: run, name: name, actionType: type, startedDate: start,
                finishedDate: seconds.map { start.addingTimeInterval($0) }, executionProgress: seconds == nil ? .running : .complete,
                completionStatus: completion, isRequiredToPass: nil
            )
        }
        var runs: [CIBuildRun] = []
        var actions: [String: [CIBuildAction]] = [:]
        for index in 1...3 {
            let id = "debug-\(index)"
            let begin = now.addingTimeInterval(-86_400 * Double(index))
            runs.append(run(id, number: index, started: begin, finished: begin.addingTimeInterval(120 + usual), progress: .complete, completion: .succeeded))
            actions[id] = [
                action(id, "Build", .build, start: begin, seconds: 120, completion: .succeeded),
                action(id, "Test", .test, start: begin.addingTimeInterval(120), seconds: usual, completion: .succeeded),
            ]
        }
        let begin = now.addingTimeInterval(-210)
        let current = run("debug-now", number: 4, started: begin, finished: nil, progress: .running, completion: nil)
        runs.append(current)
        actions[current.id] = [
            action(current.id, "Build", .build, start: begin, seconds: 120, completion: .succeeded),
            action(current.id, "Test", .test, start: begin.addingTimeInterval(120), seconds: nil, completion: nil),
        ]
        return BuildRing(run: current, in: BuildSnapshot(runs: runs, actionsByRunID: actions), now: now)
    }
    #endif
}

/// Draws a `BuildRing` into the image of the status item with Core Graphics. SwiftUI's canvas cannot be drawn into an
/// `NSImage`, and the colours have to be resolved when the image is drawn, for the menu bar it is drawn in; the geometry is
/// that of `BuildRingView` (`BuildRingMetrics`, the arcs of the model with their round ends taken out of their length).
nonisolated enum MenuBarRingPainter {
    struct Colors {
        let label: CGColor
        let running: CGColor
        let failure: CGColor
        let muted: CGColor

        /// Resolved now, in the appearance the image is being drawn in.
        static func current() -> Colors {
            func resolved(_ color: NSColor) -> CGColor { (color.usingColorSpace(.sRGB) ?? color).cgColor }
            return Colors(
                label: resolved(.labelColor), running: resolved(.systemBlue), failure: resolved(.systemRed), muted: resolved(.systemGray)
            )
        }
    }

    private static let trackOpacity: CGFloat = 0.14
    private static let paleOpacity: CGFloat = 0.32

    static func draw(_ ring: BuildRing, in context: CGContext, canvas: CGFloat, size: CGFloat, colors: Colors) {
        let width = BuildRingMetrics.lineWidth(for: size)
        let radius = BuildRingMetrics.radius(size: size, lineWidth: width, index: 0)
        let center = CGPoint(x: canvas / 2, y: canvas / 2)
        let geometry = Geometry(context: context, center: center, radius: radius, width: width)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)

        switch ring.state {
        case .queued:
            geometry.dots(color: colors.label.copy(alpha: 0.6))
            return
        case .skipped:
            geometry.circle(color: colors.muted.copy(alpha: 0.5))
            return
        case .unknown where ring.status != .running:
            geometry.circle(color: color(for: ring.status, colors))
            return
        default:
            break
        }

        geometry.circle(color: colors.label.copy(alpha: trackOpacity))

        if ring.state == .unknown {
            geometry.arc(0, BuildRingPainter.spinnerLength, color: colors.running)
            geometry.head(at: BuildRingPainter.spinnerLength, tint: colors.running)
            return
        }

        for arc in ring.arcs where arc.isEstimated {
            geometry.arc(arc.start, arc.end, color: colors.label.copy(alpha: paleOpacity))
        }
        for arc in ring.arcs where arc.marker == .dashed {
            geometry.arc(arc.start, arc.end, color: colors.muted.copy(alpha: paleOpacity))
        }
        for arc in ring.arcs where arc.solidLength > 1e-9 {
            geometry.arc(arc.start, arc.start + arc.solidLength, color: color(for: arc.status, colors))
        }

        if ring.state == .overrun, let overflow = ring.overflow, overflow > 0 {
            geometry.lap(to: overflow, tint: colors.running)
            geometry.head(at: overflow, tint: colors.running)
        } else if let head = ring.head {
            geometry.head(at: head, tint: colors.running)
        }
    }

    private static func color(for status: BuildStatus, _ colors: Colors) -> CGColor {
        switch status {
        case .succeeded, .finished: colors.label
        case .running: colors.running
        case .failed, .errored: colors.failure
        case .canceled, .skipped: colors.muted
        }
    }

    private struct Geometry {
        let context: CGContext
        let center: CGPoint
        let radius: CGFloat
        let width: CGFloat

        private func point(_ turns: Double, radius: CGFloat) -> CGPoint {
            let angle = turns * 2 * .pi
            return CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y + radius * CGFloat(cos(angle)))
        }

        func circle(color: CGColor?) {
            guard let color else { return }
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }

        /// From `start` to `end` in turns, the round ends inside that span as in `BuildRingPainter`.
        func arc(_ start: Double, _ end: Double, color: CGColor?, width: CGFloat? = nil, radius: CGFloat? = nil) {
            guard let color, end > start else { return }
            let width = width ?? self.width
            let radius = radius ?? self.radius
            if end - start >= 1 - 1e-6 {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                return
            }
            let capTurns = Double(width) / (2 * Double.pi * Double(radius))
            var from = start + capTurns / 2
            var to = end - capTurns / 2
            if to <= from {
                from = (start + end) / 2
                to = from + 1e-4
            }
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.addArc(
                center: center, radius: radius, startAngle: .pi / 2 - from * 2 * .pi, endAngle: .pi / 2 - to * 2 * .pi, clockwise: true
            )
            context.strokePath()
        }

        func dots(color: CGColor?) {
            guard let color else { return }
            let count = 12
            context.setFillColor(color)
            for index in 0..<count {
                let at = point(Double(index) / Double(count), radius: radius)
                context.fillEllipse(in: CGRect(x: at.x - 0.65, y: at.y - 0.65, width: 1.3, height: 1.3))
            }
        }

        /// The second lap of a build that outlasted its usual duration: a thinner, deeper stroke cut into the first.
        func lap(to turns: Double, tint: CGColor) {
            let thin = width * 0.5
            context.saveGState()
            context.setBlendMode(.clear)
            arc(0, turns, color: .black, width: width * 0.77)
            context.restoreGState()
            arc(0, turns, color: tint.copy(alpha: 1), width: thin)
        }

        /// The present moment: a white point on the arc. Still, as nothing moves in the bar.
        func head(at turns: Double, tint: CGColor) {
            let at = point(turns, radius: radius)
            context.setFillColor(tint)
            context.fillEllipse(in: CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: at.x - 0.8, y: at.y - 0.8, width: 1.6, height: 1.6))
        }
    }
}
