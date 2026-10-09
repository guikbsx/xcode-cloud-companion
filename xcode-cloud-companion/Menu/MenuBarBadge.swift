import AppKit

/// The dot on the menu bar icon: what Xcode Cloud is doing right now, or how the last build went.
nonisolated enum MenuBarBadge: Sendable, Equatable {
    case running
    case failed
    case succeeded
    /// Canceled, skipped, or ended without a known outcome.
    case stopped

    /// Blue while any app builds; otherwise the outcome of the last build, however old; nothing before any build.
    static func status(for snapshot: BuildSnapshot) -> MenuBarBadge? {
        if snapshot.runs.contains(where: { BuildStatus(run: $0) == .running }) {
            return .running
        }
        let last = snapshot.runs
            .filter { $0.createdDate != nil }
            .max { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
        guard let last else { return nil }
        switch BuildStatus(run: last) {
        case .failed, .errored: return .failed
        case .succeeded: return .succeeded
        case .canceled, .skipped, .finished: return .stopped
        case .running: return .running
        }
    }

    /// The same colours as the dots of the menu.
    var color: NSColor {
        switch self {
        case .running: .systemBlue
        case .failed: .systemRed
        case .succeeded: .systemGreen
        case .stopped: .systemGray
        }
    }

    static func accessibilityLabel(for badge: MenuBarBadge?) -> String {
        switch badge {
        case .running?: String(localized: "Cumulus, a build is running")
        case .failed?: String(localized: "Cumulus, the last build failed")
        case .succeeded?: String(localized: "Cumulus, the last build succeeded")
        case .stopped?: String(localized: "Cumulus, the last build was canceled")
        case nil: String(localized: "Cumulus")
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
