import Foundation
import Observation

/// What the pointer and the keyboard have opened on the figure: at most one bubble (the day of a square) and at most one
/// drawer (the durations of a workflow). The view hands it the content when it asks to open; this only decides which is
/// open and when, so the delays and the exclusions are the same under a pointer, a click and the keyboard.
@Observable
@MainActor
final class OverviewFigureInteraction {
    /// The square a pointer or the keyboard is on, by workflow and by column of the days on screen.
    struct Spot: Hashable {
        let rowID: String
        let column: Int
    }

    struct Bubble: Identifiable, Equatable {
        let spot: Spot
        let detail: OverviewDayDetail
        let swatch: AppSwatch
        let productID: String

        var id: String { "\(spot.rowID)#\(spot.column)" }
    }

    struct Drawer: Equatable {
        let rowID: String
        let series: OverviewDurationSeries
    }

    /// How long a pointer rests on a square or on a name before anything opens, and before it closes again.
    struct Delays {
        var open: Duration = .milliseconds(400)
        /// From one open bubble to the next square: no need to wait again.
        var swap: Duration = .milliseconds(120)
        var close: Duration = .milliseconds(300)
        var drawerClose: Duration = .milliseconds(450)
    }

    private(set) var bubble: Bubble?
    private(set) var drawer: Drawer?
    /// The bubble is drawn by the host (a test), not presented as a popover.
    var presentsPopover = true
    var delays = Delays()

    private var pendingBubble: Task<Void, Never>?
    private var pendingSpot: Spot?
    private var pendingBubbleClose: Task<Void, Never>?
    private var pendingDrawer: Task<Void, Never>?
    private var pendingDrawerClose: Task<Void, Never>?
    private var isPointerInBubble = false

    var litSpot: Spot? { bubble?.spot }

    // MARK: Bubble

    /// A click, or Space or Return: opens at once; a second click on the open square closes it.
    func toggleBubble(_ make: @autoclosure () -> Bubble?, at spot: Spot) {
        cancelBubbleTimers()
        if bubble?.spot == spot {
            bubble = nil
        } else {
            bubble = make()
        }
    }

    func openBubble(_ make: @autoclosure () -> Bubble?) {
        cancelBubbleTimers()
        bubble = make()
    }

    /// The pointer rests on a square.
    func pointerEntered(_ spot: Spot, make: @escaping () -> Bubble?) {
        pendingBubbleClose?.cancel()
        pendingBubbleClose = nil
        if bubble?.spot == spot {
            cancelPendingBubble()
            return
        }
        // Moving inside the square it already waits on does not restart the wait.
        if pendingSpot == spot, pendingBubble != nil { return }
        pendingBubble?.cancel()
        pendingSpot = spot
        let wait = bubble == nil ? delays.open : delays.swap
        pendingBubble = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingBubble = nil
            self.pendingSpot = nil
            if let next = make() { self.bubble = next }
        }
    }

    /// The pointer left the squares. The bubble stays a moment, so that the pointer can reach it.
    func pointerLeftSquares() {
        cancelPendingBubble()
        scheduleBubbleClose()
    }

    /// The pointer is on the bubble itself, or has left it.
    func pointerInBubble(_ inside: Bool) {
        isPointerInBubble = inside
        if inside {
            pendingBubbleClose?.cancel()
            pendingBubbleClose = nil
        } else {
            scheduleBubbleClose()
        }
    }

    func closeBubble() {
        cancelBubbleTimers()
        bubble = nil
    }

    /// The popover was dismissed by the system (Escape, a click elsewhere).
    func bubbleWasDismissed(_ id: String) {
        guard bubble?.id == id else { return }
        cancelBubbleTimers()
        bubble = nil
    }

    private func scheduleBubbleClose() {
        guard bubble != nil, !isPointerInBubble else { return }
        pendingBubbleClose?.cancel()
        let wait = delays.close
        pendingBubbleClose = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingBubbleClose = nil
            self.bubble = nil
        }
    }

    private func cancelPendingBubble() {
        pendingBubble?.cancel()
        pendingBubble = nil
        pendingSpot = nil
    }

    private func cancelBubbleTimers() {
        cancelPendingBubble()
        pendingBubbleClose?.cancel()
        pendingBubbleClose = nil
        isPointerInBubble = false
    }

    // MARK: Drawer

    /// A button, or the keyboard: opens the workflow's drawer, or closes it when it is the open one.
    func toggleDrawer(_ rowID: String, make: () -> Drawer?) {
        cancelDrawerTimers()
        if drawer?.rowID == rowID {
            drawer = nil
        } else if let next = make() {
            drawer = next
        }
    }

    /// The pointer rests on the name of a workflow.
    func pointerEnteredName(_ rowID: String, make: @escaping () -> Drawer?) {
        pendingDrawerClose?.cancel()
        pendingDrawerClose = nil
        pendingDrawer?.cancel()
        pendingDrawer = nil
        guard drawer?.rowID != rowID else { return }
        let wait = delays.open
        pendingDrawer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingDrawer = nil
            if let next = make() { self.drawer = next }
        }
    }

    func pointerLeftName() {
        pendingDrawer?.cancel()
        pendingDrawer = nil
    }

    /// The pointer left the figure: the drawer closes unless the pointer comes back.
    func pointerLeftFigure() {
        pointerLeftName()
        guard drawer != nil else { return }
        pendingDrawerClose?.cancel()
        let wait = delays.drawerClose
        pendingDrawerClose = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingDrawerClose = nil
            self.drawer = nil
        }
    }

    func pointerEnteredFigure() {
        pendingDrawerClose?.cancel()
        pendingDrawerClose = nil
    }

    func closeDrawer() {
        cancelDrawerTimers()
        drawer = nil
    }

    /// Everything is closed: the squares or the workflows on screen changed under it.
    func reset() {
        closeBubble()
        closeDrawer()
    }

    private func cancelDrawerTimers() {
        pendingDrawer?.cancel()
        pendingDrawer = nil
        pendingDrawerClose?.cancel()
        pendingDrawerClose = nil
    }
}
