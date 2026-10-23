import Foundation

/// The flaky tests of each workflow, read once from the build details already on disk, for the Overview's small notes.
/// Nothing is asked of Apple, and the reading runs off the main thread: the screen calls it when it opens and after a
/// sync, never on a redraw.
nonisolated enum OverviewFlakyTests {
    /// Builds read per workflow, newest first: enough to see a flip on one commit, not enough to scan the whole cache.
    static let buildsPerWorkflow = 30

    /// One workflow's flaky tests, named “Class/test”, the one that failed most first.
    struct Entry: Equatable, Sendable {
        let workflowID: String
        let tests: [String]
    }

    /// Workflows with no flaky test are left out.
    @concurrent static func read(workflowIDs: [String], in snapshot: BuildSnapshot, cache: BuildExtrasCache = BuildExtrasCache()) async -> [Entry] {
        var entries: [Entry] = []
        for workflowID in workflowIDs {
            let runs = TestHealthReport.eligibleRuns(workflowID: workflowID, in: snapshot).prefix(buildsPerWorkflow)
            var samples: [TestHealthReport.Sample] = []
            for run in runs {
                let extras = await cache.load(runID: run.id)
                if let sample = TestHealthReport.sample(of: run, actions: snapshot.actionsByRunID[run.id] ?? [], extras: extras) {
                    samples.append(sample)
                }
            }
            if let entry = entry(workflowID: workflowID, report: TestHealthReport(samples: samples, eligibleBuilds: runs.count)) {
                entries.append(entry)
            }
        }
        return entries
    }

    static func entry(workflowID: String, report: TestHealthReport) -> Entry? {
        let names = report.flaky.map { test in [test.className, test.name].compactMap(\.self).joined(separator: "/") }
        return names.isEmpty ? nil : Entry(workflowID: workflowID, tests: names)
    }
}
