import SwiftUI
import Testing
@testable import XcodeCloudCompanion

struct BuildRingViewTests {
    @Test func theStrokeFollowsTheSizeOfTheRing() {
        #expect(BuildRingMetrics.lineWidth(for: 16) == 2.5)
        #expect(BuildRingMetrics.lineWidth(for: 26) == 3.5)
        #expect(BuildRingMetrics.lineWidth(for: 36) == 4.5)
        #expect(BuildRingMetrics.lineWidth(for: 40) == 5)
        #expect(BuildRingMetrics.lineWidth(for: 56) == 6)
        #expect(BuildRingMetrics.lineWidth(for: 96) == 10)
        #expect(abs(BuildRingMetrics.lineWidth(for: 48) - 5.5) < 1e-9)
        #expect(BuildRingMetrics.lineWidth(for: 8) < BuildRingMetrics.lineWidth(for: 16))
    }

    @Test func concentricRingsAreOneStrokeAndThreePointsApart() {
        let radii = (0..<3).map { BuildRingMetrics.radius(size: 132, lineWidth: 11, index: $0) }
        #expect(radii == [60.5, 46.5, 32.5])
    }

    @Test func aRingNeverCollapsesUnderItsOwnStroke() {
        #expect(BuildRingMetrics.radius(size: 20, lineWidth: 6, index: 5) >= 3)
    }
}
