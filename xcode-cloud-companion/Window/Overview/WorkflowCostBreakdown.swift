import Foundation

/// Where a workflow's minutes of the cycle went, split with the same model the usage is estimated with. The total is the
/// Overview's own figure: each build's minutes (billed by Apple, or estimated) are shared out in proportion to its actions.
nonisolated struct WorkflowCostBreakdown: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case build
        case analyze
        case archive
        /// The tests of one destination, by its device name.
        case tests(destination: String)
        /// The few minutes each test machine takes to get ready.
        case preparation
        /// Tests paid twice on a destination where one of them failed.
        case reruns
        /// Test actions whose per-device results Apple would not give: counted whole, by their duration.
        case testsNotSplit
        /// Builds Apple billed that the app no longer has the actions of, and anything of an unknown kind.
        case other
    }

    struct Item: Identifiable, Equatable, Sendable {
        let kind: Kind
        let minutes: Double
        /// Share of the workflow's total, 0...1.
        let share: Double

        var id: Kind { kind }
    }

    /// A statement the figures carry out, never an advice: each case holds the numbers it is made of.
    enum Finding: Equatable, Sendable {
        case destinations(count: Int, share: Double)
        case reruns(minutes: Double)
        case preparationOutweighsTests(preparationMinutes: Double, testMinutes: Double)
    }

    var items: [Item] = []
    var billedMinutes: Double = 0
    var estimatedMinutes: Double = 0
    var buildCount = 0
    var estimatedBuildCount = 0
    var destinationCount = 0
    /// Test actions given up on: their time is in `testsNotSplit`, and the split by destination is incomplete.
    var unsplitTestActions = 0

    var totalMinutes: Double { billedMinutes + estimatedMinutes }
    var isEstimated: Bool { estimatedMinutes > 0 }

    func minutes(_ kind: Kind) -> Double {
        items.first { $0.kind == kind }?.minutes ?? 0
    }

    var testMinutes: Double {
        items.reduce(0) { total, item in
            if case .tests = item.kind { total + item.minutes } else { total }
        }
    }

    var findings: [Finding] {
        guard totalMinutes > 0 else { return [] }
        var findings: [Finding] = []
        let preparation = minutes(.preparation)
        let reruns = minutes(.reruns)
        if destinationCount >= 2 {
            findings.append(.destinations(count: destinationCount, share: (testMinutes + preparation + reruns) / totalMinutes))
        }
        if reruns >= 1 {
            findings.append(.reruns(minutes: reruns))
        }
        if testMinutes > 0, preparation > testMinutes {
            findings.append(.preparationOutweighsTests(preparationMinutes: preparation, testMinutes: testMinutes))
        }
        return findings
    }

    /// `product` and `workflow` are the names `UsageSummary.byWorkflow` uses: the product name, and the workflow's or its stand-in.
    init(product: String, workflow: String, snapshot: BuildSnapshot, ledger: UsageLedger, plan: UsagePlan, now: Date, calendar: Calendar = .current) {
        let cycle = plan.cycle(containing: now, calendar: calendar)
        let productNames = Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ratios = WorkflowRatios(snapshot: snapshot, ledger: ledger, productNames: productNames, now: now)
        let model = MachineModel(snapshot: snapshot)
        let standIn = String(localized: "Other workflows")
        func isThisWorkflow(_ name: String?) -> Bool { (name ?? standIn) == workflow }
        func isInCycle(_ date: Date) -> Bool { cycle.contains(date) && date <= now }

        var seconds: [Kind: Double] = [:]
        var destinations: Set<String> = []
        var runsByKey: [String: CIBuildRun] = [:]
        for run in snapshot.runs {
            guard let number = run.number, (productNames[run.productID] ?? run.productID) == product else { continue }
            runsByKey["\(product)#\(number)"] = run
        }

        /// Shares `minutes` out between the kinds in proportion to what the model says each action cost.
        func add(_ minutes: Double, of run: CIBuildRun?) {
            var parts: [Kind: Double] = [:]
            for action in run.map({ snapshot.actionsByRunID[$0.id] ?? [] }) ?? [] {
                let cost = model.cost(of: action, now: now)
                for device in cost.devices {
                    parts[.tests(destination: device.name), default: 0] += device.tests
                    parts[.reruns, default: 0] += device.rerun
                    parts[.preparation, default: 0] += device.preparation
                    destinations.insert(device.name)
                }
                guard cost.compute > 0 else { continue }
                switch action.actionType {
                case .build?: parts[.build, default: 0] += cost.compute
                case .analyze?: parts[.analyze, default: 0] += cost.compute
                case .archive?: parts[.archive, default: 0] += cost.compute
                case .test?:
                    // A completed test action without device results was given up on; one that never ran its tests has an empty list.
                    if action.executionProgress == .complete, snapshot.testDevicesByActionID[action.id] == nil {
                        unsplitTestActions += 1
                    }
                    parts[.testsNotSplit, default: 0] += cost.compute
                default: parts[.other, default: 0] += cost.compute
                }
            }
            let modelled = parts.values.reduce(0, +)
            guard modelled > 0 else {
                seconds[.other, default: 0] += minutes * 60
                return
            }
            for (kind, part) in parts {
                seconds[kind, default: 0] += minutes * 60 * part / modelled
            }
        }

        for build in ledger.builds.values where build.product == product && isThisWorkflow(build.workflow) && isInCycle(build.startedAt) {
            billedMinutes += Double(build.minutes)
            buildCount += 1
            add(Double(build.minutes), of: runsByKey[build.key])
        }
        for run in snapshot.runs {
            guard let number = run.number, let created = run.createdDate, (productNames[run.productID] ?? run.productID) == product,
                  isThisWorkflow(run.workflowName), isInCycle(created), ledger.billedBuild(product: product, buildNumber: number) == nil,
                  !(snapshot.actionsByRunID[run.id] ?? []).contains(where: snapshot.needsTestResults)
            else { continue }
            let minutes = ratios.estimatedMinutes(of: run, product: product, now: now)
            estimatedMinutes += minutes
            estimatedBuildCount += 1
            buildCount += 1
            add(minutes, of: run)
        }

        destinationCount = destinations.count
        let total = max(totalMinutes, 0.0001)
        items = seconds
            .filter { $0.value > 0 }
            .map { Item(kind: $0.key, minutes: $0.value / 60, share: min($0.value / 60 / total, 1)) }
            .sorted { ($0.minutes, Self.order($1.kind)) > ($1.minutes, Self.order($0.kind)) }
    }

    /// Ties keep a stable order: the usual order of a build.
    private static func order(_ kind: Kind) -> String {
        switch kind {
        case .build: "0"
        case .analyze: "1"
        case .tests(let destination): "2\(destination)"
        case .testsNotSplit: "3"
        case .preparation: "4"
        case .reruns: "5"
        case .archive: "6"
        case .other: "7"
        }
    }
}

nonisolated extension WorkflowCostBreakdown.Kind {
    var title: String {
        switch self {
        case .build: String(localized: "Build")
        case .analyze: String(localized: "Analyze")
        case .archive: String(localized: "Archive")
        case .tests(let destination): String(localized: "Tests · \(destination)", comment: "Cost of the tests on one destination, such as iPhone 17 Pro")
        case .preparation: String(localized: "Preparing the test machines")
        case .reruns: String(localized: "Tests rerun after a failure")
        case .testsNotSplit: String(localized: "Tests, not split by destination")
        case .other: String(localized: "Other")
        }
    }
}

nonisolated extension WorkflowCostBreakdown.Finding {
    /// The figures in a sentence; estimated minutes keep their ~.
    var text: String {
        switch self {
        case .destinations(let count, let share):
            String(localized: "\(count) test destinations: together, \(UsageFormat.percent(share)) of this workflow’s cost.")
        case .reruns(let minutes):
            String(localized: "Tests rerun after a failure cost ~\(UsageFormat.minutes(minutes)) this cycle.")
        case .preparationOutweighsTests(let preparation, let tests):
            String(localized: "Preparing the test machines (~\(UsageFormat.minutes(preparation))) weighs more than running the tests (~\(UsageFormat.minutes(tests))).")
        }
    }
}
