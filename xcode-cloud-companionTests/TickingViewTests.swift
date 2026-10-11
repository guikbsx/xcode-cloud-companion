import AppKit
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct TickingViewTests {
    private final class Ticks {
        var dates: [Date] = []
    }

    @Test func theNextTickFallsOnTheClock() {
        // A whole minute, so the offsets below read as seconds past it.
        let reference = Date(timeIntervalSinceReferenceDate: 600_000)

        #expect(abs(TickSchedule.delay(after: reference.addingTimeInterval(0.3), interval: 1) - 0.7) < 0.001)
        #expect(abs(TickSchedule.delay(after: reference.addingTimeInterval(20), interval: 60) - 40) < 0.001)
        // Landing a hair before the tick would draw the same second twice.
        #expect(abs(TickSchedule.delay(after: reference.addingTimeInterval(0.99), interval: 1) - 1.01) < 0.001)
        #expect(TickSchedule.delay(after: reference, interval: 0) == 1)
    }

    /// The window of an app that is not in front is where a build is watched: the counter must go on there, and its
    /// content must be drawn on the main actor, which a `TimelineView` does not promise.
    @Test func aCounterGoesOnInAWindowWhateverAppIsInFront() async throws {
        let ticks = Ticks()
        let view = TickingView(interval: 1) { now in
            let _ = ticks.dates.append(now)
            Text(BuildRowData.clock(now.timeIntervalSinceReferenceDate))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view.frame(width: 120, height: 40))
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(3_300))

        let seconds = Set(ticks.dates.map { Int($0.timeIntervalSinceReferenceDate) })
        #expect(seconds.count >= 3, "drawn for \(seconds.count) different seconds in 3.3 s")
    }
}
