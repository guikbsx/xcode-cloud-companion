import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct BuildStatusDotTests {
    private let allStatuses: [BuildStatus] = [.running, .succeeded, .failed, .errored, .canceled, .skipped, .finished]

    @Test func withoutTheSystemSettingEveryStateIsADotAndOnlyColourTellsThemApart() {
        let glyphs = allStatuses.map { BuildStatusDot.glyph(for: $0, differentiating: false) }

        #expect(glyphs == ["\u{25C9}", "\u{25CF}", "\u{25CF}", "\u{25CF}", "\u{25CF}", "\u{25CF}", "\u{25CF}"])
    }

    @Test func theMainStatesHaveAShapeOfTheirOwnWhenTheSystemAsksToDifferentiate() {
        let main: [BuildStatus] = [.running, .succeeded, .failed, .errored, .canceled]
        let glyphs = main.map { BuildStatusDot.glyph(for: $0, differentiating: true) }

        #expect(Set(glyphs).count == main.count)
        #expect(BuildStatusDot.glyph(for: .succeeded, differentiating: true) == "\u{2713}")
        #expect(BuildStatusDot.glyph(for: .failed, differentiating: true) == "\u{2715}")
    }

    @Test func theMarkerKeepsTheStatusColourWhateverTheShape() {
        for status in allStatuses {
            for differentiating in [false, true] {
                let marker = BuildStatusDot.marker(for: status, differentiating: differentiating)

                #expect(marker.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == status.color)
                #expect(marker.string.hasPrefix(BuildStatusDot.glyph(for: status, differentiating: differentiating)))
            }
        }
    }
}
