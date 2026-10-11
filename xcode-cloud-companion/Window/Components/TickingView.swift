import SwiftUI

/// Draws its content with the current time, again every `interval` seconds, on the tick of the clock.
///
/// A `TimelineView` would do, but SwiftUI calls its content on its own display queue while the app is in the background:
/// content that reads anything of the main actor then crashes, and a window watched from the corner of the eye is
/// exactly an app in the background. This one keeps the time as view state, set from a task of the main actor.
struct TickingView<Content: View>: View {
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content
    @State private var now = Date()

    var body: some View {
        content(now)
            .task(id: interval) {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(TickSchedule.delay(after: now, interval: interval)))
                }
            }
    }
}

nonisolated enum TickSchedule {
    /// How long until the next whole multiple of `interval`: two counters then change at the same instant, and a
    /// minute-by-minute view changes when the minute does.
    static func delay(after date: Date, interval: TimeInterval) -> TimeInterval {
        guard interval > 0 else { return 1 }
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: interval)
        let remaining = interval - elapsed
        // A tick that lands a hair early would show the same value twice: it waits for the next one.
        return remaining < 0.05 ? remaining + interval : remaining
    }
}
