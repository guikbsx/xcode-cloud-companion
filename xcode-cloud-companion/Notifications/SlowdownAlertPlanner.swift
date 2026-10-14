import Foundation

/// A workflow that got slower, with the banner that says so.
nonisolated struct SlowdownBreak: Sendable, Equatable {
    var workflowID: String
    var productID: String
    var runID: String
    var notification: LocalNotification
}

/// Finds the workflows that got slower since the last time one was reported. A slowdown speaks once, by the build
/// that starts it, however many syncs it stays visible in.
nonisolated enum SlowdownAlertPlanner {
    /// `reported` maps a workflow to the build whose slowdown was already said (or was already there when the
    /// account was first read). The returned map is what to keep: workflows no build names any more are dropped.
    static func evaluate(snapshot: BuildSnapshot, reported: [String: String]) -> (fresh: [SlowdownBreak], reported: [String: String]) {
        let byWorkflow = Dictionary(grouping: snapshot.runs.filter { $0.workflowID != nil }, by: { $0.workflowID ?? "" })
        var kept = reported.filter { byWorkflow[$0.key] != nil }
        var fresh: [SlowdownBreak] = []
        for (workflowID, runs) in byWorkflow.sorted(by: { $0.key < $1.key }) {
            guard let slowdown = WorkflowSlowdown(runs: runs, actionsByRunID: snapshot.actionsByRunID),
                  let run = runs.first(where: { $0.id == slowdown.buildID }),
                  let date = run.createdDate ?? run.startedDate
            else { continue }
            // An older break than the one said is the same slowdown found again with more builds; a newer one is another.
            if let known = kept[workflowID].flatMap({ id in runs.first { $0.id == id } }), !isNewer(run, than: known) { continue }
            kept[workflowID] = run.id
            let app = snapshot.product(id: run.productID)?.displayName ?? String(localized: "Build")
            let workflow = run.workflowName ?? snapshot.workflow(id: workflowID)?.name ?? "?"
            fresh.append(SlowdownBreak(
                workflowID: workflowID, productID: run.productID, runID: run.id,
                notification: LocalNotification(
                    id: "slowdown-\(run.id)",
                    title: WorkflowSlowdownText.bannerTitle(app: app, workflow: workflow, slowdown: slowdown),
                    body: WorkflowSlowdownText.bannerBody(build: run.number.map { "#\($0)" }, since: date, slowdown: slowdown),
                    url: CumulusURL.build(id: run.id),
                    thread: run.productID
                )
            ))
        }
        return (fresh, kept)
    }

    private static func isNewer(_ run: CIBuildRun, than other: CIBuildRun) -> Bool {
        (run.createdDate ?? .distantPast, run.number ?? 0) > (other.createdDate ?? .distantPast, other.number ?? 0)
    }
}
