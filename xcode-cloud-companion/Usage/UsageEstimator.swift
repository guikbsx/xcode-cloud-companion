import Foundation

/// Apple publishes no usage figure: these are the candidate ways to rebuild it from build timings.
nonisolated enum UsageMethod: String, CaseIterable, Sendable {
    case buildRunDuration
    case actionDuration
    case actionDurationRoundedUpToMinute
    /// Each simulated device billed for its own test time (Apple's model), other actions for their wall clock.
    case machineMinutes
}

/// How one build's test actions spread over devices, for the diagnostic.
nonisolated struct TestDeviceBreakdown: Sendable, Equatable {
    var deviceCount = 0
    var deviceSeconds: Double = 0
    var wallClockSeconds: Double = 0
    var actionsWithoutResults = 0
}

nonisolated struct UsageTotals: Sendable, Equatable {
    var buildCount = 0
    var seconds: [UsageMethod: TimeInterval] = [:]
    var actionCountByType: [String: Int] = [:]
    var actionSecondsByType: [String: TimeInterval] = [:]

    func seconds(_ method: UsageMethod) -> TimeInterval {
        seconds[method] ?? 0
    }
}

nonisolated enum UsageEstimator {
    /// A build counts in the interval it was created in, like App Store Connect's “Builds created”; a running build counts up to `now`.
    static func totals(
        of snapshot: BuildSnapshot,
        in interval: DateInterval,
        now: Date,
        including include: (CIBuildRun) -> Bool = { _ in true }
    ) -> UsageTotals {
        var totals = UsageTotals()
        for run in snapshot.runs where include(run) {
            guard let created = run.createdDate, interval.contains(created) else { continue }
            totals.buildCount += 1
            totals.seconds[.buildRunDuration, default: 0] += duration(from: run.startedDate, to: run.finishedDate, now: now)
            totals.seconds[.machineMinutes, default: 0] += machineSeconds(of: run, in: snapshot, now: now)
            for action in snapshot.actionsByRunID[run.id] ?? [] {
                let seconds = duration(from: action.startedDate, to: action.finishedDate, now: now)
                totals.seconds[.actionDuration, default: 0] += seconds
                totals.seconds[.actionDurationRoundedUpToMinute, default: 0] += (seconds / 60).rounded(.up) * 60
                let type = action.actionType?.rawValue ?? "UNKNOWN"
                totals.actionCountByType[type, default: 0] += 1
                totals.actionSecondsByType[type, default: 0] += seconds
            }
        }
        return totals
    }

    static func machineSeconds(of run: CIBuildRun, in snapshot: BuildSnapshot, now: Date) -> TimeInterval {
        MachineModel(snapshot: snapshot).seconds(of: run, now: now)
    }

    static func machineSeconds(of action: CIBuildAction, in snapshot: BuildSnapshot, now: Date) -> TimeInterval {
        MachineModel(snapshot: snapshot).seconds(of: action, now: now)
    }

    static func testDeviceBreakdown(of run: CIBuildRun, in snapshot: BuildSnapshot, now: Date) -> TestDeviceBreakdown {
        var breakdown = TestDeviceBreakdown()
        for action in snapshot.actionsByRunID[run.id] ?? [] where action.actionType == .test {
            breakdown.wallClockSeconds += duration(from: action.startedDate, to: action.finishedDate, now: now)
            if let devices = snapshot.testDevicesByActionID[action.id] {
                breakdown.deviceCount += devices.count
                breakdown.deviceSeconds += devices.reduce(0) { $0 + $1.totalSeconds }
            } else {
                breakdown.actionsWithoutResults += 1
            }
        }
        return breakdown
    }

    static func duration(from start: Date?, to end: Date?, now: Date) -> TimeInterval {
        guard let start else { return 0 }
        return max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// What one action costs under `MachineModel`: its own compute, or one machine per test device.
nonisolated struct ActionCost: Sendable, Equatable {
    struct Device: Sendable, Equatable {
        var name: String
        var tests: TimeInterval
        /// The tests paid a second time because one of them failed on this device.
        var rerun: TimeInterval
        var preparation: TimeInterval

        var total: TimeInterval { tests + rerun + preparation }
    }

    var compute: TimeInterval = 0
    var devices: [Device] = []

    var total: TimeInterval { devices.reduce(compute) { $0 + $1.total } }
}

/// How Apple bills a build, as measured against its usage exports (XCO-6, 09/10/2026).
///
/// Each simulated device pays its own test time plus a few minutes of preparation; a failed test is
/// retried, so a device with failures pays its tests twice. A successful archive, build or analyze action
/// is billed for its compute only, not for the upload that follows: its shortest successful run stands in
/// for that compute. Anything else pays its wall clock.
nonisolated struct MachineModel: Sendable {
    static let deviceOverhead: TimeInterval = 4.5 * 60
    static let failureRetryFactor = 2.0
    static let minimumSamplesForCap = 3

    private let snapshot: BuildSnapshot
    private let computeCaps: [String: TimeInterval]

    init(snapshot: BuildSnapshot) {
        self.snapshot = snapshot
        var samples: [String: [TimeInterval]] = [:]
        for run in snapshot.runs {
            for action in snapshot.actionsByRunID[run.id] ?? [] where action.completionStatus == .succeeded && action.actionType != .test {
                guard let started = action.startedDate, let finished = action.finishedDate else { continue }
                samples[Self.capKey(productID: run.productID, action: action), default: []].append(finished.timeIntervalSince(started))
            }
        }
        computeCaps = samples.compactMapValues { $0.count >= Self.minimumSamplesForCap ? $0.min() : nil }
    }

    func seconds(of run: CIBuildRun, now: Date) -> TimeInterval {
        (snapshot.actionsByRunID[run.id] ?? []).reduce(0) { $0 + seconds(of: $1, now: now) }
    }

    func seconds(of action: CIBuildAction, now: Date) -> TimeInterval {
        cost(of: action, now: now).total
    }

    /// The same figure as `seconds(of:now:)`, with what it is made of.
    func cost(of action: CIBuildAction, now: Date) -> ActionCost {
        let wallClock = UsageEstimator.duration(from: action.startedDate, to: action.finishedDate, now: now)
        if action.actionType == .test {
            // No device results on a completed test action: the tests never ran (compile error).
            guard let devices = snapshot.testDevicesByActionID[action.id], !devices.isEmpty else { return ActionCost(compute: wallClock) }
            return ActionCost(devices: devices.map { device in
                ActionCost.Device(
                    name: device.deviceName, tests: device.totalSeconds,
                    rerun: device.failedCount > 0 ? device.totalSeconds * (Self.failureRetryFactor - 1) : 0, preparation: Self.deviceOverhead
                )
            })
        }
        guard action.completionStatus == .succeeded,
              let run = snapshot.runs.first(where: { $0.id == action.buildRunID }),
              let cap = computeCaps[Self.capKey(productID: run.productID, action: action)]
        else { return ActionCost(compute: wallClock) }
        return ActionCost(compute: min(wallClock, cap))
    }

    private static func capKey(productID: String, action: CIBuildAction) -> String {
        "\(productID)|\(action.actionType?.rawValue ?? "")"
    }
}
