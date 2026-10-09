import AppKit

/// The dot on the menu bar icon: what Xcode Cloud is doing right now, or how the last build went.
nonisolated enum MenuBarBadge: Sendable, Equatable {
    case running
    case failed
    case succeeded

    /// A finished build keeps its dot for this long, then the icon goes back to rest.
    static let quietAfter: TimeInterval = 10 * 60

    /// Blue while any app builds; otherwise the last build's outcome for ten minutes; nothing for a cancelled or old build.
    static func status(for snapshot: BuildSnapshot, now: Date) -> MenuBarBadge? {
        if snapshot.runs.contains(where: { BuildStatus(run: $0) == .running }) {
            return .running
        }
        let last = snapshot.runs
            .filter { $0.createdDate != nil }
            .max { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
        guard let last, let reference = last.finishedDate ?? last.createdDate,
              now.timeIntervalSince(reference) <= quietAfter
        else { return nil }
        switch BuildStatus(run: last) {
        case .failed, .errored: return .failed
        case .succeeded: return .succeeded
        case .running, .canceled, .skipped, .finished: return nil
        }
    }

    var color: NSColor {
        switch self {
        case .running: .systemBlue
        case .failed: .systemRed
        case .succeeded: .systemGreen
        }
    }

    static func accessibilityLabel(for badge: MenuBarBadge?) -> String {
        switch badge {
        case .running?: String(localized: "Cumulus, a build is running")
        case .failed?: String(localized: "Cumulus, the last build failed")
        case .succeeded?: String(localized: "Cumulus, the last build succeeded")
        case nil: String(localized: "Cumulus")
        }
    }
}

/// Where the dot goes on the status button: the lower right corner of the drawn cloud, half in and half out.
nonisolated enum MenuBarBadgePlacement {
    /// `imageAreaMid` is the middle of the cell's image rectangle: the cell centres the image in it, whatever its height.
    /// The status button is flipped (y grows downward), which is why the vertical edge depends on `isFlipped`.
    static func frameOrigin(imageAreaMid: NSPoint, imageSize: NSSize, glyph: NSRect, badgeSize: CGFloat, isFlipped: Bool) -> NSPoint {
        let imageOrigin = NSPoint(x: imageAreaMid.x - imageSize.width / 2, y: imageAreaMid.y - imageSize.height / 2)
        let centerX = imageOrigin.x + glyph.maxX - 1
        let centerY = isFlipped
            ? imageOrigin.y + imageSize.height - glyph.minY - 1
            : imageOrigin.y + glyph.minY + 1
        return NSPoint(x: centerX - badgeSize / 2, y: centerY - badgeSize / 2)
    }
}

/// The dot itself, laid over the template cloud so the cloud keeps following the menu bar's appearance.
final class MenuBarBadgeView: NSView {
    static let size: CGFloat = 14

    var badge: MenuBarBadge? {
        didSet {
            isHidden = badge == nil
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MenuBarBadgeView is never decoded")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let badge else { return }
        let differentiating = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        let diameter: CGFloat = differentiating ? 11 : 8
        let dot = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        if badge == .running {
            badge.color.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()
        }
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(ovalIn: dot.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        badge.color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        if differentiating {
            Self.mark(for: badge, in: dot)
        }
    }

    /// A white shape on the dot, so the state does not rest on colour alone.
    private static func mark(for badge: MenuBarBadge, in dot: NSRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: dot.minX + dot.width * x, y: dot.minY + dot.height * y)
        }
        NSColor.white.setStroke()
        NSColor.white.setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch badge {
        case .succeeded:
            path.move(to: point(0.25, 0.5))
            path.line(to: point(0.43, 0.3))
            path.line(to: point(0.76, 0.7))
            path.stroke()
        case .failed:
            path.move(to: point(0.3, 0.3))
            path.line(to: point(0.7, 0.7))
            path.move(to: point(0.3, 0.7))
            path.line(to: point(0.7, 0.3))
            path.stroke()
        case .running:
            NSBezierPath(ovalIn: NSRect(x: dot.midX - 1.5, y: dot.midY - 1.5, width: 3, height: 3)).fill()
        }
    }
}

extension NSImage {
    /// Bounding box of the pixels actually drawn, in points from the image's lower left corner: a symbol's image carries margins.
    var drawnBounds: NSRect {
        let scale = 4
        let width = max(1, Int(size.width.rounded(.up))) * scale
        let height = max(1, Int(size.height.rounded(.up))) * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSRect(origin: .zero, size: size) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                minX = min(minX, x); maxX = max(maxX, x)
                // Bitmap rows run top to bottom; the result is measured from the bottom.
                minY = min(minY, height - 1 - y); maxY = max(maxY, height - 1 - y)
            }
        }
        guard maxX >= 0 else { return NSRect(origin: .zero, size: size) }
        let factor = CGFloat(scale)
        return NSRect(x: CGFloat(minX) / factor, y: CGFloat(minY) / factor, width: CGFloat(maxX - minX + 1) / factor, height: CGFloat(maxY - minY + 1) / factor)
    }
}
