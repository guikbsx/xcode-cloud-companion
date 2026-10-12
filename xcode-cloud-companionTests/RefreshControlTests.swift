import Testing
@testable import XcodeCloudCompanion

@Suite("Refresh control of the toolbar")
struct RefreshControlTests {
    private let plenty = RateLimit(limit: 3600, remaining: 3000)

    @Test("Nothing under way: the button refreshes")
    func ready() {
        let control = RefreshControl.current(isSyncing: false, isLoading: false, lastError: nil, budget: plenty)
        #expect(control == .ready)
        #expect(control.allowsRefresh)
    }

    @Test("No budget read yet is not a reason to hold the button")
    func unknownBudget() {
        #expect(RefreshControl.current(isSyncing: false, isLoading: false, lastError: nil, budget: nil) == .ready)
    }

    @Test("A sync under way shows the spinner and refuses a refresh")
    func syncing() {
        let control = RefreshControl.current(isSyncing: true, isLoading: false, lastError: nil, budget: plenty)
        #expect(control == .busy)
        #expect(!control.allowsRefresh)
        // Busy is not held: the button keeps its full colour while its symbol turns.
        #expect(!control.isHeld)
    }

    @Test("What the window reads for itself counts as a request under way")
    func loading() {
        #expect(RefreshControl.current(isSyncing: false, isLoading: true, lastError: nil, budget: plenty) == .busy)
    }

    @Test("A request under way comes before any reason to hold")
    func busyFirst() {
        let spent = RateLimit(limit: 3600, remaining: 10)
        #expect(RefreshControl.current(isSyncing: true, isLoading: false, lastError: .rateLimited, budget: spent) == .busy)
    }

    @Test("After a 429 the button is held: another refusal would double the wait")
    func rateLimited() {
        let control = RefreshControl.current(isSyncing: false, isLoading: false, lastError: .rateLimited, budget: plenty)
        #expect(control == .held(.rateLimited))
        #expect(!control.allowsRefresh)
        #expect(control.isHeld)
    }

    @Test("Another error leaves the button: trying again is the way out")
    func otherError() {
        #expect(RefreshControl.current(isSyncing: false, isLoading: false, lastError: .invalidResponse, budget: plenty) == .ready)
    }

    @Test("The button is held at the critical budget, and free just above it")
    func lowBudget() {
        let critical = RateLimit(limit: 3600, remaining: SyncSchedule.criticalRemaining)
        let above = RateLimit(limit: 3600, remaining: SyncSchedule.criticalRemaining + 1)
        #expect(RefreshControl.current(isSyncing: false, isLoading: false, lastError: nil, budget: critical) == .held(.lowBudget))
        #expect(RefreshControl.current(isSyncing: false, isLoading: false, lastError: nil, budget: above) == .ready)
    }
}
