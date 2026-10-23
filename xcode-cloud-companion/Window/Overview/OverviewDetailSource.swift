import Foundation

/// What the bubble of a square and the drawer of a workflow read: the snapshot and what the app already holds in memory.
/// Opening either one asks for nothing and reads nothing from the disk.
nonisolated struct OverviewDetailSource: Sendable {
    var snapshot = BuildSnapshot()
    var now = Date()
    var calendar = Calendar.current
    /// The categories of failed builds already known, by build; empty while “In brief” is closed.
    var categories: [String: FailureCategory] = [:]
    /// The sentences of “In brief” already known, by build; empty while that function is closed.
    var insights: [String: String] = [:]
    var pro: Set<ProFeature> = []

    /// The drawer is Cumulus Pro's (`ProFeature.workflowTrends`): without it the name of a workflow only opens its sheet.
    var allowsDrawer: Bool { pro.contains(.workflowTrends) }

    func dayDetail(row: OverviewMosaic.Row, appName: String, day: Date) -> OverviewDayDetail? {
        OverviewDayDetail(
            day: day, row: row, appName: appName, snapshot: snapshot, now: now, calendar: calendar, categories: categories, insights: insights
        )
    }

    /// Nil without Pro.
    func durationSeries(row: OverviewMosaic.Row) -> OverviewDurationSeries? {
        guard allowsDrawer else { return nil }
        return OverviewDurationSeries(row: row, snapshot: snapshot, now: now, calendar: calendar)
    }
}
