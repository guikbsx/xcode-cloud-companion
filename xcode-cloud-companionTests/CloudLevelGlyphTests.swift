import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct CloudLevelGlyphTests {
    private func inkedPixels(_ image: NSImage) -> Int {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 76, pixelsHigh: 56, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 76, height: 56))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<56 {
            for x in 0..<76 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                count += 1
            }
        }
        return count
    }

    @Test func theGlyphIsATemplateSoTheMenuBarTintsIt() {
        let image = CloudLevelGlyph.image(level: 0.4)

        #expect(image.isTemplate)
        #expect(image.size == CloudLevelGlyph.size)
    }

    @Test func theCloudFillsUpWithTheUsage() {
        let unknown = inkedPixels(CloudLevelGlyph.image(level: nil))
        let empty = inkedPixels(CloudLevelGlyph.image(level: 0))
        let half = inkedPixels(CloudLevelGlyph.image(level: 0.5))
        let full = inkedPixels(CloudLevelGlyph.image(level: 1))

        #expect(unknown == empty)
        #expect(half > empty)
        #expect(full > half)
        #expect(inkedPixels(CloudLevelGlyph.image(level: 3)) == full)
    }
}
