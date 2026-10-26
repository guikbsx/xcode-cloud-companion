import Foundation

/// The ways to turn a build's timings into minutes. Apple billed one workflow by each device's own test time,
/// then by the test action's wall clock (XCO-197): each workflow follows the one that best foretold its latest billed builds.
nonisolated enum EstimateFormula: String, Codable, CaseIterable, Sendable {
    /// `MachineModel`: each test device for its own tests plus preparation, the other actions for their compute.
    case machine
    /// Every action for its wall clock.
    case actionWallClock
    /// Each test device for the test action's whole wall clock, the other actions as `machine` counts them.
    case deviceWallClock

    func minutes(of run: CIBuildRun, in snapshot: BuildSnapshot, model: MachineModel, now: Date) -> Double {
        (snapshot.actionsByRunID[run.id] ?? []).reduce(0) { $0 + cost(of: $1, in: snapshot, model: model, now: now).total } / 60
    }

    /// What one action costs under this formula, split the way « Why a workflow costs » shows it (XCO-200).
    func cost(of action: CIBuildAction, in snapshot: BuildSnapshot, model: MachineModel, now: Date) -> ActionCost {
        let wallClock = UsageEstimator.duration(from: action.startedDate, to: action.finishedDate, now: now)
        let devices = action.actionType == .test ? snapshot.testDevicesByActionID[action.id] ?? [] : []
        switch self {
        case .machine:
            return model.cost(of: action, now: now)
        case .actionWallClock:
            guard !devices.isEmpty else { return ActionCost(compute: wallClock) }
            // The action's duration, shared between its destinations by their own test time.
            let tests = devices.reduce(0) { $0 + $1.totalSeconds }
            return ActionCost(devices: devices.map { device in
                let share = tests > 0 ? device.totalSeconds / tests : 1 / Double(devices.count)
                return ActionCost.Device(name: device.deviceName, tests: wallClock * share, rerun: 0, preparation: 0)
            })
        case .deviceWallClock:
            guard !devices.isEmpty else { return model.cost(of: action, now: now) }
            return ActionCost(devices: devices.map { ActionCost.Device(name: $0.deviceName, tests: wallClock, rerun: 0, preparation: 0) })
        }
    }
}

/// One build both billed by Apple and measured by Cumulus: what it cost, and what each formula said it would.
nonisolated struct CalibrationSample: Codable, Sendable, Equatable {
    var product: String
    var workflow: String?
    var buildNumber: Int
    var created: Date
    var billedMinutes: Int
    /// By the formula's raw value: a formula added later is missing from older samples.
    var minutes: [String: Double]

    var key: String { "\(product)#\(buildNumber)" }
    var workflowKey: String { WorkflowRatios.key(product: product, workflow: workflow) }

    func minutes(_ formula: EstimateFormula) -> Double? { minutes[formula.rawValue] }
}

/// What the estimate has learned from the usage exports, kept once the builds leave the 35-day cache (XCO-199).
nonisolated struct UsageCalibration: Codable, Sendable, Equatable {
    static let samplesPerWorkflow = 30
    static let retention: TimeInterval = 365 * 24 * 3600

    /// By product and build number.
    var samples: [String: CalibrationSample] = [:]

    /// The builds of `snapshot` that Apple billed, are finished and are measured (test results read).
    static func samples(
        from snapshot: BuildSnapshot, ledger: UsageLedger, productNames: [String: String], model: MachineModel, now: Date
    ) -> [CalibrationSample] {
        snapshot.runs.compactMap { run in
            let product = productNames[run.productID] ?? run.productID
            guard run.executionProgress == .complete, let number = run.number,
                  let billed = ledger.billedBuild(product: product, buildNumber: number),
                  let actions = snapshot.actionsByRunID[run.id], !actions.isEmpty,
                  // Results still on their way would make the build look cheap.
                  !actions.contains(where: snapshot.needsTestResults)
            else { return nil }
            return CalibrationSample(
                product: product, workflow: run.workflowName, buildNumber: number, created: run.createdDate ?? billed.startedAt,
                billedMinutes: billed.minutes,
                minutes: Dictionary(uniqueKeysWithValues: EstimateFormula.allCases.map { ($0.rawValue, $0.minutes(of: run, in: snapshot, model: model, now: now)) })
            )
        }
    }

    /// Adds the samples not known yet, a sample once written is kept as it was; true when something changed.
    @discardableResult
    mutating func learn(_ new: [CalibrationSample], now: Date) -> Bool {
        let before = samples
        for sample in new where samples[sample.key] == nil {
            samples[sample.key] = sample
        }
        let oldest = now.addingTimeInterval(-Self.retention)
        let kept = Dictionary(grouping: samples.values.filter { $0.created >= oldest }, by: \.workflowKey)
            .values.flatMap { $0.sorted { $0.created > $1.created }.prefix(Self.samplesPerWorkflow) }
        samples = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        return samples != before
    }
}
