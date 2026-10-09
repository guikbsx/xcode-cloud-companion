import Foundation

nonisolated struct BuildSynchronizer: Sendable {
    /// A billing cycle is at most 31 days; a few extra days cover a cycle that started before the window.
    static let window: TimeInterval = 35 * 24 * 3600
    static let maxConcurrentActionRequests = 4
    /// A first sync has dozens of test actions, each several pages deep: the rest waits for the next sync.
    static let maxTestResultFetchesPerSync = 12

    let client: AppStoreConnectClient
    var progress: @Sendable (String) -> Void = { _ in }

    /// Builds already known as complete are kept as they are: only new builds and builds still running are asked again.
    @concurrent func sync(from previous: BuildSnapshot, now: Date) async throws(AppStoreConnectError) -> BuildSnapshot {
        let windowStart = now.addingTimeInterval(-Self.window)
        progress(String(localized: "Listing apps…"))
        let products = try await client.products()

        var runs: [CIBuildRun] = []
        var workflows: [CIWorkflow] = []
        for product in products {
            progress(String(localized: "Listing builds of \(product.name)…"))
            // Workflow details only refine the estimate: when Apple fails to list them, last sync's are kept.
            if let fetched = try? await client.workflows(productID: product.id) {
                workflows += fetched
            } else {
                workflows += previous.workflows.filter { workflow in previous.runs.contains { $0.productID == product.id && $0.workflowID == workflow.id } }
            }
            let cached = previous.runs(forProductID: product.id).filter { run in
                run.createdDate.map { $0 >= windowStart } ?? false
            }
            let refreshSince = Self.refreshStart(for: cached, windowStart: windowStart)
            let fetched = try await client.buildRuns(productID: product.id, createdSince: refreshSince)
            runs += Self.merge(fetched: fetched, cached: cached, refreshSince: refreshSince)
        }

        var actionsByRunID: [String: [CIBuildAction]] = [:]
        var runsNeedingActions: [String] = []
        for run in runs {
            if run.executionProgress == .complete,
               let cached = previous.actionsByRunID[run.id],
               cached.allSatisfy({ $0.executionProgress == .complete }) {
                actionsByRunID[run.id] = cached
            } else {
                runsNeedingActions.append(run.id)
            }
        }
        progress(String(localized: "Fetching actions of \(runsNeedingActions.count) builds…"))
        for (runID, actions) in try await fetchActions(for: runsNeedingActions) {
            actionsByRunID[runID] = actions
        }

        // Per-device results are final once a test action completes; they are fetched once and kept.
        var testDevicesByActionID: [String: [CITestDeviceRun]] = [:]
        var actionsNeedingDevices: [String] = []
        for run in runs {
            for action in actionsByRunID[run.id] ?? [] where action.actionType == .test && action.executionProgress == .complete {
                if let cached = previous.testDevicesByActionID[action.id] {
                    testDevicesByActionID[action.id] = cached
                } else {
                    actionsNeedingDevices.append(action.id)
                }
            }
        }
        // Hundreds of requests on a first sync: one failure skips that action until the next sync, a rate limit stops the series.
        let batch = Array(actionsNeedingDevices.prefix(Self.maxTestResultFetchesPerSync))
        for (actionID, devices) in await fetchTestDevices(for: batch, total: actionsNeedingDevices.count) {
            testDevicesByActionID[actionID] = devices
        }

        return BuildSnapshot(
            products: products,
            runs: runs,
            actionsByRunID: actionsByRunID,
            testDevicesByActionID: testDevicesByActionID,
            workflows: workflows,
            lastSuccessfulSync: now
        )
    }

    /// Paging stops at the newest cached build, unless an older cached build is still running.
    static func refreshStart(for cached: [CIBuildRun], windowStart: Date) -> Date {
        guard let newest = cached.compactMap(\.createdDate).max() else { return windowStart }
        let oldestActive = cached.filter { $0.executionProgress != .complete }.compactMap(\.createdDate).min()
        return max(windowStart, min(newest, oldestActive ?? newest))
    }

    static func merge(fetched: [CIBuildRun], cached: [CIBuildRun], refreshSince: Date) -> [CIBuildRun] {
        let fetchedIDs = Set(fetched.map(\.id))
        let kept = cached.filter { run in
            !fetchedIDs.contains(run.id) && (run.createdDate.map { $0 < refreshSince } ?? false)
        }
        return (fetched + kept).sorted { ($0.number ?? 0) > ($1.number ?? 0) }
    }

    private func fetchActions(for runIDs: [String]) async throws(AppStoreConnectError) -> [(String, [CIBuildAction])] {
        try await fetchConcurrently(runIDs) { [client] id throws(AppStoreConnectError) in try await client.buildActions(buildRunID: id) }
    }

    /// Complete test actions whose per-device results are still to be fetched.
    static func pendingTestResultCount(in snapshot: BuildSnapshot) -> Int {
        snapshot.actionsByRunID.values.joined().filter {
            $0.actionType == .test && $0.executionProgress == .complete && snapshot.testDevicesByActionID[$0.id] == nil
        }.count
    }

    private func fetchTestDevices(for actionIDs: [String], total: Int) async -> [(String, [CITestDeviceRun])] {
        guard !actionIDs.isEmpty else { return [] }
        let progress = progress
        progress(String(localized: "Fetching test results (0/\(total))…"))
        let fetchOne: @Sendable (String) async throws(AppStoreConnectError) -> [CITestDeviceRun]? = { [client] id throws(AppStoreConnectError) in
            do {
                return try await client.testDeviceRuns(buildActionID: id)
            } catch AppStoreConnectError.rateLimited {
                throw AppStoreConnectError.rateLimited
            } catch {
                return nil
            }
        }
        let results: [(String, [CITestDeviceRun]?)] = (try? await fetchConcurrently(actionIDs, onEach: { done in
            progress(String(localized: "Fetching test results (\(done)/\(total))…"))
        }, fetchOne)) ?? []
        return results.compactMap { (id: String, devices: [CITestDeviceRun]?) in devices.map { (id, $0) } }
    }

    private func fetchConcurrently<Value: Sendable>(
        _ ids: [String],
        onEach: @escaping @Sendable (Int) -> Void = { _ in },
        _ fetch: @escaping @Sendable (String) async throws(AppStoreConnectError) -> Value
    ) async throws(AppStoreConnectError) -> [(String, Value)] {
        do {
            return try await withThrowingTaskGroup(of: (String, Value).self) { group in
                var results: [(String, Value)] = []
                var pending = ids[...]
                func addNext() {
                    guard let id = pending.popFirst() else { return }
                    group.addTask { (id, try await fetch(id)) }
                }
                for _ in 0..<Self.maxConcurrentActionRequests { addNext() }
                while let result = try await group.next() {
                    results.append(result)
                    onEach(results.count)
                    addNext()
                }
                return results
            }
        } catch let error as AppStoreConnectError {
            throw error
        } catch {
            throw .network(.cancelled)
        }
    }
}
