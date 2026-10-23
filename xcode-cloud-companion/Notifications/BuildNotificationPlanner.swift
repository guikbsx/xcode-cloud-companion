import Foundation

/// Which builds are worth a banner, as chosen in Settings.
nonisolated struct BuildNotificationRules: Sendable, Equatable {
    static let stuckFactors = [2, 3, 5]
    static let defaultStuckFactor = 3

    var succeeded = true
    var failed = true
    /// Off by default: a push on a pull request cancels the build before it, which says nothing new.
    var canceled = false
    var stuck = true
    /// How many times its usual duration an action runs before the build is taken to be stuck.
    var stuckFactor = BuildNotificationRules.defaultStuckFactor
    /// Apps are notified unless muted, so a new app speaks up without a visit to Settings.
    var mutedProductIDs: Set<String> = []
    /// A build started by `cumulus run` or an MCP tool: the user learns at once that an agent spent minutes.
    var agentLaunches = true
    /// A TestFlight build given to groups, taken from them or expired by `cumulus testflight` or an MCP tool.
    var agentTestFlight = true
    /// A workflow whose successful builds got slower, said once by the build that starts it.
    var slowdown = true
    /// A TestFlight build that external testers can install, said once.
    var testFlightAvailable = true
    /// The build external testers are on, a week from expiring, said once.
    var testFlightExpiry = true

    var notifiesAnything: Bool { succeeded || failed || canceled || stuck || slowdown || testFlightAvailable || testFlightExpiry }

    func includes(_ status: BuildStatus) -> Bool {
        switch status {
        case .succeeded: succeeded
        case .failed, .errored: failed
        case .canceled: canceled
        case .running, .skipped, .finished: false
        }
    }
}

/// Turns two consecutive snapshots into banners. Nothing is pushed by Apple: a build "just finished" when the sync
/// saw it running before and complete now.
nonisolated enum BuildNotificationPlanner {
    /// A build that ended longer ago than this (the Mac slept, the network was down) is old news.
    static let freshness: TimeInterval = 3600
    static let minimumSamplesForUsualDuration = 3
    /// A short action is not stuck for running a few minutes over.
    static let minimumOverrun: TimeInterval = 10 * 60

    static func finished(previous: BuildSnapshot, current: BuildSnapshot, rules: BuildNotificationRules, now: Date) -> [LocalNotification] {
        finishedBuilds(previous: previous, current: current, rules: rules, now: now).map(\.notification)
    }

    /// The same banners, with the build each one is about: a failed one may be enriched before it is posted.
    static func finishedBuilds(previous: BuildSnapshot, current: BuildSnapshot, rules: BuildNotificationRules, now: Date) -> [FinishedBuildBanner] {
        // The first load has no "before": every build in it was already over.
        guard let previousSync = previous.lastSuccessfulSync else { return [] }
        let before = Dictionary(previous.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.runs.compactMap { run in
            guard run.executionProgress == .complete, !rules.mutedProductIDs.contains(run.productID) else { return nil }
            if let known = before[run.id] {
                guard known.executionProgress != .complete else { return nil }
            } else {
                // Started and finished between two syncs.
                guard let created = run.createdDate, created > previousSync else { return nil }
            }
            guard now.timeIntervalSince(run.finishedDate ?? now) <= freshness else { return nil }
            let status = BuildStatus(run: run)
            guard rules.includes(status) else { return nil }
            return FinishedBuildBanner(run: run, status: status, notification: notification(for: run, status: status, in: current))
        }
    }

    /// One banner per build whose running action has outlasted its usual duration by far.
    static func stuck(in snapshot: BuildSnapshot, rules: BuildNotificationRules, alreadyReported: Set<String>, now: Date) -> [StuckBuild] {
        guard rules.stuck else { return [] }
        return snapshot.runs.compactMap { run in
            guard run.executionProgress != .complete, !alreadyReported.contains(run.id), !rules.mutedProductIDs.contains(run.productID) else { return nil }
            for action in snapshot.actionsByRunID[run.id] ?? [] where action.executionProgress == .running {
                guard let started = action.startedDate, let usual = usualSeconds(of: action, run: run, in: snapshot) else { continue }
                let elapsed = now.timeIntervalSince(started)
                guard elapsed >= max(usual * Double(rules.stuckFactor), usual + minimumOverrun) else { continue }
                return StuckBuild(runID: run.id, notification: LocalNotification(
                    id: "stuck-\(run.id)",
                    title: String(localized: "\(appName(of: run, in: snapshot)) #\(number(of: run)) may be stuck", comment: "Notification title: app name, then build number."),
                    body: String(
                        localized: "\(action.name ?? "?") has been running for \(UsageFormat.minutes(elapsed / 60)), usually \(UsageFormat.minutes(usual / 60)).",
                        comment: "Notification body: action name, time it has run, its usual duration."
                    ),
                    url: CumulusURL.build(id: run.id),
                    thread: run.productID
                ))
            }
            return nil
        }
    }

    /// The median time the same action took when it succeeded in the same workflow; nil below three samples.
    static func usualSeconds(of action: CIBuildAction, run: CIBuildRun, in snapshot: BuildSnapshot) -> TimeInterval? {
        guard let workflowID = run.workflowID, let name = action.name else { return nil }
        var samples: [TimeInterval] = []
        for other in snapshot.runs where other.workflowID == workflowID && other.id != run.id {
            for sample in snapshot.actionsByRunID[other.id] ?? [] where sample.name == name && sample.completionStatus == .succeeded {
                guard let started = sample.startedDate, let finished = sample.finishedDate else { continue }
                samples.append(finished.timeIntervalSince(started))
            }
        }
        samples.sort()
        guard samples.count >= minimumSamplesForUsualDuration else { return nil }
        let middle = samples.count / 2
        return samples.count.isMultiple(of: 2) ? (samples[middle - 1] + samples[middle]) / 2 : samples[middle]
    }

    // MARK: - Private

    private static func notification(for run: CIBuildRun, status: BuildStatus, in snapshot: BuildSnapshot) -> LocalNotification {
        let app = appName(of: run, in: snapshot)
        let number = number(of: run)
        let title = switch status {
        case .succeeded: String(localized: "\(app) #\(number) succeeded", comment: "Notification title: app name, then build number.")
        case .canceled: String(localized: "\(app) #\(number) was canceled", comment: "Notification title: app name, then build number.")
        default: String(localized: "\(app) #\(number) failed", comment: "Notification title: app name, then build number.")
        }
        var parts: [String] = []
        if status == .failed || status == .errored {
            if let failures = run.issueCounts?.testFailures, failures > 0 {
                parts.append(String(localized: "\(failures) test failures"))
            } else if let errors = run.issueCounts?.errors, errors > 0 {
                parts.append(String(localized: "\(errors) errors"))
            }
        }
        parts += [run.workflowName, run.sourceBranchOrTag].compactMap(\.self).filter { !$0.isEmpty }
        if status == .succeeded, let started = run.startedDate, let finished = run.finishedDate {
            parts.append(UsageFormat.minutes(finished.timeIntervalSince(started) / 60))
        }
        return LocalNotification(id: "build-\(run.id)", title: title, body: UsageFormat.dotted(parts), url: CumulusURL.build(id: run.id), thread: run.productID)
    }

    private static func appName(of run: CIBuildRun, in snapshot: BuildSnapshot) -> String {
        snapshot.product(id: run.productID)?.displayName ?? String(localized: "Build")
    }

    private static func number(of run: CIBuildRun) -> String {
        run.number.map(String.init) ?? "?"
    }
}

nonisolated struct FinishedBuildBanner: Sendable, Equatable {
    var run: CIBuildRun
    var status: BuildStatus
    var notification: LocalNotification

    var isFailure: Bool { status == .failed || status == .errored }
}

nonisolated struct StuckBuild: Sendable, Equatable {
    var runID: String
    var notification: LocalNotification
}
