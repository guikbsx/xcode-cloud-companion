import AppKit

/// The menu bar glyph: a cloud outline whose bottom fills up with the cycle's usage, under a wavy level line.
enum CloudLevelGlyph {
    static let size = NSSize(width: 19, height: 14)

    /// The reference drawing lives in a 100 × 64 box; only the part holding the cloud is drawn.
    private static let origin = NSPoint(x: 10, y: 6)
    private static let scale: CGFloat = 0.22
    /// Level line when the cloud is empty and when it is full, in the reference box.
    private static let emptyLevel: CGFloat = 58
    private static let fullLevel: CGFloat = 12

    /// `level` is the share of the plan used, 0…1; `nil` while it is unknown, which leaves the outline alone.
    static func image(level: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -origin.x, y: -origin.y)
            NSColor.black.set()
            let cloud = cloudPath()
            if let level, level > 0 {
                NSGraphicsContext.saveGraphicsState()
                cloud.addClip()
                wave(at: emptyLevel - (emptyLevel - fullLevel) * CGFloat(min(level, 1))).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            cloud.lineWidth = 7
            cloud.lineJoinStyle = .round
            cloud.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Cumulus")
        return image
    }

    /// The cloud of the reference drawing (y grows downward): a flat bottom and three arcs.
    private static func cloudPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 26, y: 58))
        path.line(to: NSPoint(x: 74, y: 58))
        appendArc(to: path, center: NSPoint(x: 74, y: 42), radius: 16, start: 90, sweep: -180)
        appendArc(to: path, center: NSPoint(x: 53.592, y: 34.217), radius: 22, start: -21.93, sweep: -147.02)
        appendArc(to: path, center: NSPoint(x: 29, y: 44), radius: 14.318, start: -77.91, sweep: -180)
        path.close()
        return path
    }

    /// Arcs as short segments: the angles are those of the reference drawing, whatever the context's orientation.
    private static func appendArc(to path: NSBezierPath, center: NSPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat) {
        let steps = 24
        for step in 1...steps {
            let angle = (start + sweep * CGFloat(step) / CGFloat(steps)) * .pi / 180
            path.line(to: NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
    }

    /// Everything below a wavy line at height `y`, wider than the cloud so the clip trims it.
    private static func wave(at y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y))
        var control = NSPoint(x: 12, y: y - 6)
        for x in stride(from: CGFloat(25), through: 100, by: 25) {
            path.curve(to: NSPoint(x: x, y: y), controlPoint: control)
            control = NSPoint(x: 2 * x - control.x, y: 2 * y - control.y)
        }
        path.line(to: NSPoint(x: 100, y: 70))
        path.line(to: NSPoint(x: 0, y: 70))
        path.close()
        return path
    }
}
