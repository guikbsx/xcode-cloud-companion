import Foundation

/// Where a loading skeleton stands in for data that is on its way. A skeleton is shown only while a load is pending
/// and content is expected from it; when the load ends with nothing, the place goes back to what it showed before.
nonisolated enum SkeletonRules {
    /// The “In Brief” card of a failed build: until its record is known, while the load has not ended without one.
    static func failureInsight(hasRecord: Bool, isLoading: Bool, hasAttempted: Bool) -> Bool {
        !hasRecord && (isLoading || !hasAttempted)
    }

    /// The TestFlight card of a build: only a succeeded build of a workflow that ships to TestFlight has a build to list.
    static func testFlightCard(shipsToTestFlight: Bool, isSucceeded: Bool, hasBuilds: Bool, loadEnded: Bool) -> Bool {
        shipsToTestFlight && isSucceeded && !hasBuilds && !loadEnded
    }

    /// The Tests tab: nothing is known yet and at least one test action has finished, so its results are on their way.
    static func testsTab(isPending: Bool, hasResults: Bool, actions: [CIBuildAction]) -> Bool {
        isPending && !hasResults && actions.contains { $0.actionType == .test && $0.executionProgress == .complete }
    }

    /// The Issues tab: an action that may have issues is still to be read.
    static func issuesTab(isPending: Bool, hasRows: Bool, actions: [CIBuildAction]) -> Bool {
        isPending && !hasRows && actions.contains { ($0.issueCounts?.total ?? 1) > 0 }
    }

    /// The Artifacts tab: a finished action is still to be asked for its files.
    static func artifactsTab(isPending: Bool, hasRows: Bool, actions: [CIBuildAction]) -> Bool {
        isPending && !hasRows && actions.contains { $0.executionProgress == .complete }
    }

    /// The pill of the last TestFlight build of an app: a build is known to have gone there, its reading has not ended.
    static func testFlightPill(hasShippedRun: Bool, hasText: Bool, loadEnded: Bool) -> Bool {
        hasShippedRun && !hasText && !loadEnded
    }

    /// The cycle card at the top of the sidebar: the plan and its reset date are set, the first measure is under way.
    static func sidebarCycle(hasPlan: Bool, isMeasuring: Bool) -> Bool {
        hasPlan && isMeasuring
    }

    /// The state of Cumulus Pro and its actions, until StoreKit has been read once.
    static func proSettings(hasResolved: Bool) -> Bool {
        !hasResolved
    }

    /// What a workflow sheet reads from the workflow's own request: the workflow in view only has the sync's partial copy.
    static func workflowSheet(isCached: Bool, loadEnded: Bool) -> Bool {
        !isCached && !loadEnded
    }
}

extension ExtrasLoadState {
    /// Not read yet, or being read.
    var isPending: Bool {
        switch self {
        case .idle, .loading: true
        case .failed, .loaded: false
        }
    }
}
