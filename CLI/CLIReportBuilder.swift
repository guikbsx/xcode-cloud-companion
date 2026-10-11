import Foundation

/// Turns the cache into the command's answers. Pure: the same data and clock give the same answer.
nonisolated struct CLIReportBuilder: Sendable {
    let data: CLIData
    let now: Date
    let calendar: Calendar

    private var snapshot: BuildSnapshot { data.snapshot }

    private var productNames: [String: String] {
        Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func summary() -> UsageSummary? {
        data.plan.map { UsageCalculator.summary(snapshot: snapshot, ledger: data.ledger, plan: $0, now: now, calendar: calendar) }
    }

    private static let noPlanHint = "Set the plan and its reset date in Cumulus › Settings › Accounts to get the cycle's figures."

    // MARK: - Status and usage

    func status() -> (StatusOutput, isEstimate: Bool) {
        let usage = summary().map(usageOutput)
        let output = StatusOutput(
            planConfigured: data.plan != nil,
            usage: usage,
            runningBuilds: snapshot.runs.filter { $0.executionProgress != .complete }.count,
            appCount: snapshot.products.count,
            hint: data.plan == nil ? Self.noPlanHint : nil
        )
        return (output, (usage?.estimatedMinutes ?? 0) > 0)
    }

    func usage(_ breakdown: UsageBreakdown) -> (UsageReportOutput, isEstimate: Bool) {
        guard let summary = summary() else {
            return (UsageReportOutput(planConfigured: false, hint: Self.noPlanHint), false)
        }
        var output = UsageReportOutput(planConfigured: true, summary: usageOutput(summary))
        output.costliestBuild = summary.costliestBuild.map {
            UsageReportOutput.CostliestBuild(
                app: $0.product, number: $0.buildNumber, reference: "\($0.product)#\($0.buildNumber)", workflow: $0.workflow,
                minutes: CLINumber.minutes($0.minutes), isEstimated: $0.isEstimated
            )
        }
        switch breakdown {
        case .summary:
            break
        case .byApp:
            output.byApp = summary.byApp.map {
                UsageReportOutput.App(
                    app: $0.product, billedMinutes: CLINumber.minutes($0.billedMinutes),
                    estimatedMinutes: CLINumber.minutes($0.estimatedMinutes), totalMinutes: CLINumber.minutes($0.totalMinutes)
                )
            }
        case .byWorkflow:
            output.byWorkflow = summary.byWorkflow.map {
                UsageReportOutput.Workflow(
                    app: $0.product, workflow: $0.workflow, buildCount: $0.buildCount,
                    billedMinutes: CLINumber.minutes($0.billedMinutes), estimatedMinutes: CLINumber.minutes($0.estimatedMinutes),
                    totalMinutes: CLINumber.minutes($0.totalMinutes), averageMinutes: CLINumber.minutes($0.averageMinutes)
                )
            }
        case .daily:
            let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
            output.daily = summary.daily.map {
                UsageReportOutput.Day(
                    day: $0.day.formatted(style), billedMinutes: CLINumber.minutes($0.billedMinutes),
                    estimatedMinutes: CLINumber.minutes($0.estimatedMinutes), totalMinutes: CLINumber.minutes($0.totalMinutes)
                )
            }
        }
        return (output, summary.estimatedMinutes > 0)
    }

    private func usageOutput(_ summary: UsageSummary) -> UsageOutput {
        let measurement = summary.measurement
        return UsageOutput(
            planHours: summary.plan.hours,
            quotaMinutes: CLINumber.minutes(summary.quotaMinutes),
            billedMinutes: CLINumber.minutes(summary.billedMinutes),
            estimatedMinutes: CLINumber.minutes(summary.estimatedMinutes),
            usedMinutes: CLINumber.minutes(summary.usedMinutes),
            remainingMinutes: CLINumber.minutes(summary.availableMinutes),
            fractionUsed: CLINumber.fraction(summary.fractionUsed),
            cycleStart: summary.cycle.start,
            resetDate: summary.resetDate,
            projectedMinutes: summary.projectedMinutes.map(CLINumber.minutes),
            exhaustionDate: summary.exhaustionDate,
            estimatedBuildCount: summary.estimatedBuildCount,
            lastImport: summary.lastImport,
            importIsStale: summary.isImportStale,
            measurement: UsageOutput.Measurement(
                isMeasuring: measurement.isMeasuring, pendingBuilds: measurement.pendingBuilds,
                measuredActions: measurement.measuredActions, totalActions: measurement.totalActions,
                unmeasurableActions: measurement.unmeasurableActions
            ),
            note: measurement.isMeasuring
                ? "Cumulus is still measuring \(measurement.pendingBuilds) builds of this cycle: the estimate will grow as their test results arrive."
                : nil
        )
    }

    // MARK: - Apps

    func apps() -> ([AppOutput], isEstimate: Bool) {
        let summary = summary()
        let outputs = snapshot.products.map { product -> AppOutput in
            let runs = sorted(snapshot.runs(forProductID: product.id))
            let usage = summary?.byApp.first { $0.product == product.name }
            return AppOutput(
                id: product.id, name: product.name, storeName: product.appName, bundleID: product.bundleID, type: product.productType,
                latestBuild: runs.first.map { brief($0, productName: product.name) },
                runningBuilds: runs.filter { $0.executionProgress != .complete }.count,
                cycle: summary.map { _ in
                    MinutesOutput(
                        billedMinutes: CLINumber.minutes(usage?.billedMinutes ?? 0),
                        estimatedMinutes: CLINumber.minutes(usage?.estimatedMinutes ?? 0),
                        totalMinutes: CLINumber.minutes(usage?.totalMinutes ?? 0)
                    )
                }
            )
        }
        return (outputs, outputs.contains { ($0.cycle?.estimatedMinutes ?? 0) > 0 })
    }

    // MARK: - Builds

    func builds(_ query: BuildsQuery) throws(CLIFailure) -> ([BuildOutput], isEstimate: Bool) {
        var runs = snapshot.runs
        if let app = query.app {
            let product = try CLIReference.product(app, in: snapshot)
            runs = runs.filter { $0.productID == product.id }
        }
        if query.failed || query.running {
            runs = runs.filter { run in
                let isRunning = run.executionProgress == .pending || run.executionProgress == .running
                let hasFailed = run.completionStatus == .failed || run.completionStatus == .errored
                return (query.running && isRunning) || (query.failed && hasFailed)
            }
        }
        if let since = query.since {
            runs = runs.filter { ($0.createdDate ?? $0.startedDate).map { $0 >= since } ?? false }
        }
        let limit = min(max(1, query.limit), BuildsQuery.maximumLimit)
        let estimator = MinutesEstimator(data: data, productNames: productNames, now: now)
        let outputs = sorted(runs).prefix(limit).map { build($0, estimator: estimator) }
        return (outputs, outputs.contains { $0.estimatedMinutes != nil })
    }

    private func sorted(_ runs: [CIBuildRun]) -> [CIBuildRun] {
        runs.sorted { (date(of: $0), $0.number ?? 0) > (date(of: $1), $1.number ?? 0) }
    }

    private func date(of run: CIBuildRun) -> Date {
        run.createdDate ?? run.startedDate ?? .distantPast
    }

    private func reference(_ run: CIBuildRun, productName: String) -> String? {
        run.number.map { "\(productName)#\($0)" }
    }

    private func brief(_ run: CIBuildRun, productName: String) -> BuildBrief {
        BuildBrief(
            id: run.id, reference: reference(run, productName: productName), number: run.number,
            status: CLIStatusWord.word(progress: run.executionProgress, completion: run.completionStatus),
            createdDate: run.createdDate, finishedDate: run.finishedDate
        )
    }

    private func build(_ run: CIBuildRun, estimator: MinutesEstimator) -> BuildOutput {
        let productName = productNames[run.productID] ?? run.productID
        let minutes = estimator.minutes(of: run)
        var source: BuildOutput.Source?
        if run.isPullRequestBuild == true || run.pullRequestNumber != nil {
            source = BuildOutput.Source(
                kind: "pullRequest", name: run.sourceBranchOrTag, pullRequestNumber: run.pullRequestNumber, pullRequestTitle: run.pullRequestTitle
            )
        } else if let name = run.sourceBranchOrTag {
            source = BuildOutput.Source(kind: "branchOrTag", name: name)
        }
        return BuildOutput(
            id: run.id,
            reference: reference(run, productName: productName),
            app: productName,
            productID: run.productID,
            number: run.number,
            workflow: run.workflowName,
            workflowID: run.workflowID,
            source: source,
            status: CLIStatusWord.word(progress: run.executionProgress, completion: run.completionStatus),
            executionProgress: run.executionProgress.rawValue,
            completionStatus: run.completionStatus?.rawValue,
            startReason: run.startReason,
            cancelReason: run.cancelReason,
            createdDate: run.createdDate,
            startedDate: run.startedDate,
            finishedDate: run.finishedDate,
            durationSeconds: run.startedDate.map { CLINumber.seconds(UsageEstimator.duration(from: $0, to: run.finishedDate, now: now)) },
            commit: run.sourceCommit.map {
                BuildOutput.Commit(sha: $0.commitSha, shortSha: $0.shortSha, message: $0.message, author: $0.authorName, url: $0.webURL)
            },
            issueCounts: run.issueCounts,
            billedMinutes: minutes.billed.map(CLINumber.minutes),
            estimatedMinutes: minutes.estimated.map(CLINumber.minutes)
        )
    }

    // MARK: - One build

    func build(reference: String, extras: BuildExtras?) throws(CLIFailure) -> (BuildDetailOutput, isEstimate: Bool) {
        let run = try CLIReference.run(reference, in: snapshot)
        let actions = snapshot.actionsByRunID[run.id] ?? []
        let actionNames = Dictionary(actions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let estimator = MinutesEstimator(data: data, productNames: productNames, now: now)
        let build = build(run, estimator: estimator)

        let allIssues = actions.flatMap { extras?.issuesByAction[$0.id] ?? [] }
        let serious = allIssues.filter { $0.type == .error || $0.type == .testFailure }
        let warnings = allIssues.filter { $0.type != .error && $0.type != .testFailure }
        let listed = serious + warnings.prefix(BuildDetailOutput.maximumWarnings)
        let tests = actions.flatMap { extras?.testsByAction[$0.id] ?? [] }
        let failed = tests.filter(\.status.isFailure)
        let skipped = tests.filter { $0.status == .skipped }.count

        var hint: String?
        if extras == nil {
            hint = run.executionProgress == .complete
                ? "Issues, test results and artifacts are not in the cache: start Cumulus ('cumulus refresh') and ask again, or open this build with 'cumulus open \(build.reference ?? run.id)'."
                : "This build is still running: its issues and test results come once it finishes."
        }

        let output = BuildDetailOutput(
            build: build,
            actions: actions.map { action in
                BuildDetailOutput.Action(
                    id: action.id, name: action.name, type: action.actionType?.rawValue,
                    status: CLIStatusWord.word(progress: action.executionProgress, completion: action.completionStatus),
                    executionProgress: action.executionProgress.rawValue, completionStatus: action.completionStatus?.rawValue,
                    isRequiredToPass: action.isRequiredToPass, startedDate: action.startedDate, finishedDate: action.finishedDate,
                    durationSeconds: action.startedDate.map { CLINumber.seconds(UsageEstimator.duration(from: $0, to: action.finishedDate, now: now)) },
                    issueCounts: action.issueCounts,
                    testDevices: snapshot.testDevicesByActionID[action.id].map { devices in
                        devices.map {
                            BuildDetailOutput.Device(
                                deviceName: $0.deviceName, osVersion: $0.osVersion, testCount: $0.testCount,
                                failedCount: $0.failedCount, seconds: CLINumber.seconds($0.totalSeconds)
                            )
                        }
                    }
                )
            },
            detailsAvailable: extras != nil,
            detailsLoaded: BuildDetailOutput.Loaded(
                issues: extras?.issuesComplete ?? false, tests: extras?.testsComplete ?? false, artifacts: extras?.artifactsComplete ?? false
            ),
            issues: listed.map {
                BuildDetailOutput.Issue(
                    actionID: $0.buildActionID, action: actionNames[$0.buildActionID] ?? nil, type: $0.type.rawValue,
                    category: $0.category, message: $0.message, file: $0.file.map { FileOutput(path: $0.path, line: $0.lineNumber) }
                )
            },
            omittedWarnings: max(0, warnings.count - BuildDetailOutput.maximumWarnings),
            failedTests: failed.map { test in
                BuildDetailOutput.FailedTest(
                    actionID: test.buildActionID, className: test.className, name: test.name, status: test.status.rawValue,
                    message: test.message, file: test.file.map { FileOutput(path: $0.path, line: $0.lineNumber) },
                    devices: test.devices.map {
                        BuildDetailOutput.TestDevice(deviceName: $0.deviceName, osVersion: $0.osVersion, status: $0.status.rawValue, durationSeconds: $0.duration)
                    }
                )
            },
            testSummary: extras?.testsComplete == true
                ? BuildDetailOutput.TestSummary(total: tests.count, failed: failed.count, skipped: skipped, passed: tests.count - failed.count - skipped)
                : nil,
            artifacts: actions.flatMap { extras?.artifactsByAction[$0.id] ?? [] }.map {
                BuildDetailOutput.Artifact(actionID: $0.buildActionID, fileName: $0.fileName, fileType: $0.fileType, fileSize: $0.fileSize)
            },
            testFlightBuilds: (extras?.betaBuilds ?? []).map {
                BuildDetailOutput.TestFlightBuild(id: $0.id, version: $0.version, uploadedDate: $0.uploadedDate, processingState: $0.processingState)
            },
            links: BuildDetailOutput.Links(
                // Without the team in its path: the team is the key's Issuer ID, which never leaves the app.
                appStoreConnect: AppStoreConnectLinks.build(
                    appID: snapshot.products.first { $0.id == run.productID }?.appID, buildRunID: run.id, teamID: nil
                ),
                cumulus: "cumulus://build/\(run.id)"
            ),
            hint: hint
        )
        return (output, build.estimatedMinutes != nil)
    }

    // MARK: - Workflows

    func workflows(app: String?) throws(CLIFailure) -> ([WorkflowOutput], isEstimate: Bool) {
        let product = try app.map { reference throws(CLIFailure) in try CLIReference.product(reference, in: snapshot) }
        let summary = summary()
        // The configuration read for the window is richer: it replaces the snapshot's entry of the same workflow.
        var byID: [String: CIWorkflow] = [:]
        var order: [String] = []
        for workflow in snapshot.workflows + data.workflowDetails {
            if byID[workflow.id] == nil { order.append(workflow.id) }
            var merged = workflow
            merged.productID = workflow.productID ?? byID[workflow.id]?.productID
            byID[workflow.id] = merged
        }
        let outputs = order.compactMap { byID[$0] }
            .filter { product == nil || $0.productID == product?.id }
            .map { workflow -> WorkflowOutput in
                let productName = workflow.productID.flatMap { productNames[$0] }
                let lastRun = sorted(snapshot.runs.filter { $0.workflowID == workflow.id }).first
                let usage = summary?.byWorkflow.first { $0.product == productName && $0.workflow == workflow.name }
                return WorkflowOutput(
                    id: workflow.id, name: workflow.name, app: productName, productID: workflow.productID,
                    isEnabled: workflow.isEnabled, description: workflow.description,
                    testDestinations: workflow.testDestinationCounts.reduce(0, +),
                    actions: workflow.actions.isEmpty ? nil : workflow.actions.compactMap { $0.name ?? $0.actionType?.rawValue },
                    repository: workflow.repositoryName, xcodeVersion: workflow.xcodeVersionName, macOSVersion: workflow.macOSVersionName,
                    lastBuild: lastRun.map { brief($0, productName: productName ?? $0.productID) },
                    cycle: summary.map { _ in
                        WorkflowOutput.Cycle(
                            buildCount: usage?.buildCount ?? 0,
                            billedMinutes: CLINumber.minutes(usage?.billedMinutes ?? 0),
                            estimatedMinutes: CLINumber.minutes(usage?.estimatedMinutes ?? 0),
                            totalMinutes: CLINumber.minutes(usage?.totalMinutes ?? 0),
                            averageMinutes: CLINumber.minutes(usage?.averageMinutes ?? 0)
                        )
                    }
                )
            }
            .sorted { ($0.app ?? "", $0.name) < ($1.app ?? "", $1.name) }
        return (outputs, outputs.contains { ($0.cycle?.estimatedMinutes ?? 0) > 0 })
    }
}

/// Minutes of one build: Apple's when its usage export has it, the calibrated estimate otherwise.
nonisolated struct MinutesEstimator: Sendable {
    private let data: CLIData
    private let productNames: [String: String]
    private let now: Date
    private let model: MachineModel
    private let ratios: WorkflowRatios

    init(data: CLIData, productNames: [String: String], now: Date) {
        self.data = data
        self.productNames = productNames
        self.now = now
        model = MachineModel(snapshot: data.snapshot)
        ratios = WorkflowRatios(snapshot: data.snapshot, ledger: data.ledger, productNames: productNames, now: now)
    }

    func minutes(of run: CIBuildRun) -> (billed: Double?, estimated: Double?) {
        let product = productNames[run.productID] ?? run.productID
        if let number = run.number, let billed = data.ledger.billedBuild(product: product, buildNumber: number) {
            return (Double(billed.minutes), nil)
        }
        // Test results still on their way: no honest estimate yet, as in the app.
        guard !(data.snapshot.actionsByRunID[run.id] ?? []).contains(where: data.snapshot.needsTestResults) else { return (nil, nil) }
        return (nil, model.seconds(of: run, now: now) / 60 * ratios.ratio(product: product, workflow: run.workflowName))
    }
}
