import Foundation

/// What a failed build's banner says once its insight is known. Pure: the coordinator decides when to call it.
nonisolated enum FailureBannerFormat {
    /// How long a failed build's banner waits for its insight before it goes out as it is.
    static let waitLimit: Duration = .seconds(5)

    /// `accountName` is nil with a single account. Without a record, or for a build that did not fail, the banner is returned as it was.
    static func notification(for banner: FinishedBuildBanner, record: FailureInsightRecord?, accountName: String?) -> LocalNotification {
        var result = banner.notification
        guard banner.isFailure, let record else {
            result.subtitle = accountName
            return result
        }
        let category = record.category.displayName
        if let accountName {
            result.subtitle = accountName
            result.body = UsageFormat.dotted([category, record.headline ?? banner.notification.body])
        } else {
            result.subtitle = UsageFormat.dotted([category, banner.run.workflowName].compactMap(\.self).filter { !$0.isEmpty })
            result.body = record.headline ?? banner.notification.body
        }
        return result
    }
}

/// Where a failed build's banner gets its insight: the account's store in the app, a stand-in in tests.
protocol FailureInsightSource {
    /// Whether the feature is open for the account right now; when it is not, nothing is asked.
    var isOpen: Bool { get }
    /// The insight of a failed build, or nil when it was not ready within `timeout`. The work goes on after a timeout.
    func record(for run: CIBuildRun, within timeout: Duration) async -> FailureInsightRecord?
}

struct StoreFailureInsightSource: FailureInsightSource {
    let store: FailureInsightStore

    var isOpen: Bool { store.isOpen() }

    func record(for run: CIBuildRun, within timeout: Duration) async -> FailureInsightRecord? {
        // A window already loading the same build makes `load` return at once: wait for that one too.
        let store = store
        let loading = Task {
            await store.load(run)
            while store.isLoading(run.id) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard await BannerWait.finished(loading, within: timeout) else { return nil }
        return store.insight(for: run.id)
    }
}

nonisolated enum BannerWait {
    /// True when `work` ended before `timeout`. `work` is never cancelled: it keeps running after a timeout.
    static func finished(_ work: Task<Void, Never>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
