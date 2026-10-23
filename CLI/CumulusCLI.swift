import Foundation

nonisolated enum CumulusCLI {
    static func run(arguments: [String], environment: CLIEnvironment) async -> CLIResult {
        let invocation: CLIInvocation
        do {
            invocation = try CLIParser.parse(arguments, now: environment.now())
        } catch {
            return failure(error, format: nil, environment: environment)
        }
        if invocation.command.needsPro, let refusal = ProGate.refusal(in: environment.directory) {
            return failure(refusal, format: invocation.format, environment: environment)
        }
        if case .query(.status) = invocation.command, let refusal = await ProGate.pausedRefusal(account: invocation.account, in: environment.directory) {
            return failure(refusal, format: invocation.format, environment: environment)
        }
        switch invocation.command {
        case .help(let topic):
            guard let topic else { return CLIResult(stdout: CLIHelp.overview) }
            guard let text = CLIHelp.topic(topic) else {
                return failure(
                    CLIFailure(code: .usage, message: "Unknown command '\(topic)'.", suggestions: ["Run 'cumulus help' to list the commands."]),
                    format: invocation.format, environment: environment
                )
            }
            return CLIResult(stdout: text)
        case .version(let verbose):
            let line = "cumulus \(environment.version) (\(environment.build))\n"
            return CLIResult(stdout: verbose ? line + (await cacheInfo(environment, account: nil)) : line)
        case .cacheInfo:
            return CLIResult(stdout: await cacheInfo(environment, account: invocation.account))
        case .query(let query):
            do {
                let response = try await CLIQueryRunner(environment: environment, account: invocation.account).run(query)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .refresh(let wait, let timeout):
            do {
                let response = try await CLIQueryRunner(environment: environment, account: invocation.account).refresh(wait: wait, timeout: timeout)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .launch(let command):
            do throws(CLIFailure) {
                let runner = CLIQueryRunner(environment: environment, account: invocation.account)
                let plan = try await runner.prepareLaunch(command)
                // At a terminal, a person confirms what spends minutes; in a pipe or over MCP, the agent already decided.
                if environment.isTerminal, !command.yes,
                   !environment.confirm("Start \(plan.workflowName) on \(plan.request.source.label) for \(plan.appName)? [y/N]") {
                    return CLIResult(stdout: "Nothing started.\n")
                }
                let response = try await runner.launch(plan)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .testFlightGive(let command):
            do throws(CLIFailure) {
                let runner = CLIQueryRunner(environment: environment, account: invocation.account)
                let plan = try await runner.prepareTestFlightGive(command)
                // At a terminal, a person confirms what changes who can test a build; in a pipe or over MCP, the agent already decided.
                if environment.isTerminal, !command.yes, !environment.confirm(plan.question) {
                    return CLIResult(stdout: "Nothing changed.\n")
                }
                let response = try await runner.testFlightGive(plan)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .testFlightExpire(let command):
            do throws(CLIFailure) {
                let runner = CLIQueryRunner(environment: environment, account: invocation.account)
                let plan = try await runner.prepareTestFlightExpire(command)
                if environment.isTerminal, !command.yes, !environment.confirm(plan.question) {
                    return CLIResult(stdout: "Nothing changed.\n")
                }
                let response = try await runner.testFlightExpire(plan)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .open(let reference):
            do throws(CLIFailure) {
                let scope = try await CLIAccountScope.resolve(invocation.account, in: environment.directory)
                let snapshot = try await CLIData.load(from: scope.directory, includingUsage: false).snapshot
                let run = try CLIReference.run(reference, in: snapshot)
                guard let url = URL(string: "cumulus://build/\(run.id)"), environment.openURL(url) else {
                    throw CLIFailure(code: .internal, message: "The build could not be opened in Cumulus.", suggestions: ["Check that the Cumulus app is installed."])
                }
                return CLIResult()
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .mcp(let verbose):
            await MCPSession.runOnStandardIO(environment: environment, verbose: verbose)
            return CLIResult()
        }
    }

    private static func usesJSON(_ format: CLIOutputFormat?, _ environment: CLIEnvironment) -> Bool {
        format.map { $0 == .json } ?? !environment.isTerminal
    }

    static func render(_ response: CLIResponse, format: CLIOutputFormat?, environment: CLIEnvironment) -> String {
        guard !usesJSON(format, environment) else { return response.json }
        return CLIRenderer(width: environment.terminalWidth, now: response.meta.generatedAt, calendar: environment.calendar).text(response)
    }

    private static func failure(_ failure: CLIFailure, format: CLIOutputFormat?, environment: CLIEnvironment) -> CLIResult {
        CLIResult(stderr: usesJSON(format, environment) ? failure.json : failure.text, exitCode: failure.code.exitCode)
    }

    private static func cacheInfo(_ environment: CLIEnvironment, account: String?) async -> String {
        guard let scope = try? await CLIAccountScope.resolve(account, in: environment.directory) else {
            return "cache: \(environment.directory.path(percentEncoded: false))\nno cache yet: open Cumulus and add your App Store Connect API key\n"
        }
        let fileURL = scope.directory.appending(path: "BuildCache.json")
        var lines = ["account: \(scope.account.name)", "cache: \(fileURL.path(percentEncoded: false))"]
        if let snapshot = await BuildCacheStore(fileURL: fileURL).load() {
            lines.append("last sync: \(snapshot.lastSuccessfulSync.map { $0.formatted(.iso8601) } ?? "never")")
            lines.append("apps: \(snapshot.products.count)")
            lines.append("builds: \(snapshot.runs.count)")
        } else {
            lines.append("no cache yet: open Cumulus and add your App Store Connect API key")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Answers a query from the shared folder; the usage of the cycle is only computed for the answers that show it.
nonisolated struct CLIQueryRunner: Sendable {
    let environment: CLIEnvironment
    /// The account to answer for, by name; nil for the one on screen in the app.
    var account: String?

    /// Asks the app for a sync; once it has waited for it, the answer carries the status read from the fresh cache.
    func refresh(wait: Bool, timeout: TimeInterval?) async throws(CLIFailure) -> CLIResponse {
        // Before the app ever ran there is no account to name: it is started, and syncs the one it has.
        let scope: CLIAccountScope?
        do {
            scope = try await CLIAccountScope.resolve(account, in: environment.directory)
        } catch {
            guard account == nil, error.code == .noCache else { throw error }
            scope = nil
        }
        let (refreshed, lastSuccessfulSync) = try await CLIAppLink(environment: environment, accountID: scope?.account.id).refresh(wait: wait, timeout: timeout)
        var output = refreshed
        var meta = CLIMeta(
            lastSuccessfulSync: lastSuccessfulSync, generatedAt: environment.now(), cliVersion: environment.version, appRunning: true,
            account: scope?.account.name, showsAccount: scope?.hasSiblings ?? false
        )
        if wait, let status = try? await run(.status), case .status(let statusOutput) = status.report {
            output.status = statusOutput
            meta.lastSuccessfulSync = status.meta.lastSuccessfulSync ?? lastSuccessfulSync
            meta.isEstimate = status.meta.isEstimate
        }
        return CLIResponse(report: .refresh(output), meta: meta)
    }

    /// Everything `cumulus run` needs before it asks the person, then the app: the workflow and the source, from the cache.
    func prepareLaunch(_ command: LaunchCommand) async throws(CLIFailure) -> LaunchPlan {
        let scope = try await CLIAccountScope.resolve(account, in: environment.directory)
        let snapshot = try await CLIData.load(from: scope.directory, includingUsage: false).snapshot
        let workflow = try CLIReference.workflow(command.workflow, in: snapshot)
        let productID = workflow.productID ?? snapshot.runs.first { $0.workflowID == workflow.id }?.productID
        let product = snapshot.products.first { $0.id == productID }
        let source: IPCLaunchRequest.Source
        if let branch = command.branch {
            source = .branch(branch)
        } else if let tag = command.tag {
            source = .tag(tag)
        } else if let number = command.pullRequest {
            source = .pullRequest(number)
        } else {
            let last = snapshot.runs
                .filter { $0.workflowID == workflow.id && $0.isPullRequestBuild != true && $0.pullRequestNumber == nil && $0.sourceBranchOrTag != nil }
                .max { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            guard let branch = last?.sourceBranchOrTag else {
                throw CLIFailure(code: .usage, message: "No build of \(workflow.name) says which branch to build.", suggestions: ["Pass --branch <name>, --tag <name> or --pr <number>."])
            }
            source = .branch(branch)
        }
        return LaunchPlan(
            request: IPCLaunchRequest(workflowID: workflow.id, source: source, clean: command.clean, accountID: scope.account.id),
            workflowName: workflow.name, appName: product?.name ?? "?", accountName: scope.account.name, showsAccount: scope.hasSiblings
        )
    }

    func launch(_ plan: LaunchPlan) async throws(CLIFailure) -> CLIResponse {
        let (result, appLaunched) = try await CLIAppLink(environment: environment, accountID: plan.request.accountID).launch(plan.request)
        let source: BuildOutput.Source = switch plan.request.source {
        case .branch(let name): BuildOutput.Source(kind: "branch", name: name)
        case .tag(let name): BuildOutput.Source(kind: "tag", name: name)
        case .pullRequest(let number): BuildOutput.Source(kind: "pullRequest", pullRequestNumber: number)
        }
        let output = LaunchOutput(
            buildRunID: result.buildRunID ?? "", number: result.buildNumber, reference: result.buildNumber.map { "\(plan.appName)#\($0)" },
            app: plan.appName, workflow: plan.workflowName, source: source, clean: plan.request.clean, appLaunched: appLaunched
        )
        let meta = CLIMeta(
            lastSuccessfulSync: result.lastSuccessfulSync, generatedAt: environment.now(), cliVersion: environment.version, appRunning: true,
            account: plan.accountName, showsAccount: plan.showsAccount
        )
        return CLIResponse(report: .launch(output), meta: meta)
    }

    /// Every account with how fresh its cache is. `meta` speaks for the account on screen.
    private func accounts() async throws(CLIFailure) -> CLIResponse {
        guard let registry = await CLIAccountScope.registry(in: environment.directory) else { throw CLIFailure.noCache }
        async let appRunning = CLIAppLink(environment: environment).isAppRunning()
        var outputs: [AccountOutput] = []
        var selectedSync: Date?
        for account in registry.accounts {
            let cache = CLIAccountScope.directory(of: account, in: environment.directory).appending(path: "BuildCache.json")
            let snapshot = await BuildCacheStore(fileURL: cache).load()
            let isSelected = account.id == registry.selectedID
            if isSelected { selectedSync = snapshot?.lastSuccessfulSync }
            outputs.append(AccountOutput(
                name: account.name, selected: isSelected, lastSuccessfulSync: snapshot?.lastSuccessfulSync, appCount: snapshot?.products.count ?? 0
            ))
        }
        return CLIResponse(
            report: .accounts(outputs),
            meta: CLIMeta(
                lastSuccessfulSync: selectedSync, generatedAt: environment.now(), cliVersion: environment.version, appRunning: await appRunning,
                account: registry.selected?.name
            )
        )
    }

    func run(_ query: CLIQuery) async throws(CLIFailure) -> CLIResponse {
        // The one question that is not about an account.
        if case .accounts = query {
            return try await accounts()
        }
        let now = environment.now()
        let scope = try await CLIAccountScope.resolve(account, in: environment.directory)
        let link = CLIAppLink(environment: environment, accountID: scope.account.id)
        async let appRunning = link.isAppRunning()
        let wantsWorkflowDetails = if case .workflows = query { true } else { false }
        let data = try await CLIData.load(from: scope.directory, includingUsage: true, includingWorkflowDetails: wantsWorkflowDetails)
        let builder = CLIReportBuilder(data: data, now: now, calendar: environment.calendar)
        let report: CLIReport
        let isEstimate: Bool
        switch query {
        case .accounts:
            return try await accounts()
        case .status:
            let (output, estimate) = builder.status()
            (report, isEstimate) = (.status(output), estimate)
        case .apps:
            let (output, estimate) = builder.apps()
            (report, isEstimate) = (.apps(output), estimate)
        case .builds(let buildsQuery):
            let (output, estimate) = try builder.builds(buildsQuery)
            (report, isEstimate) = (.builds(output), estimate)
        case .build(let reference, let fetch):
            let run = try CLIReference.run(reference, in: data.snapshot)
            let cache = BuildExtrasCache(directory: scope.directory.appending(path: "BuildDetails"))
            var extras = await cache.load(runID: run.id)
            let isComplete = extras.map { $0.issuesComplete && $0.testsComplete && $0.artifactsComplete } ?? false
            if fetch, !isComplete, run.executionProgress == .complete, await link.loadDetails(buildRunID: run.id) {
                extras = await cache.load(runID: run.id)
            }
            let (output, estimate) = try builder.build(reference: run.id, extras: extras)
            (report, isEstimate) = (.build(output), estimate)
        case .workflows(let app):
            let (output, estimate) = try builder.workflows(app: app)
            (report, isEstimate) = (.workflows(output), estimate)
        case .usage(let breakdown):
            let (output, estimate) = builder.usage(breakdown)
            (report, isEstimate) = (.usage(output), estimate)
        case .testFlight(let reference, let fetch):
            let found = try await testFlightKnowledge(reference: reference, scope: scope, snapshot: data.snapshot, startingApp: false, fetch: fetch)
            let name = found.product?.name ?? found.run.productID
            let output = Self.testFlightOutput(
                run: found.run, product: found.product, reference: found.run.number.map { "\(name)#\($0)" }, knowledge: found.knowledge, now: now
            )
            (report, isEstimate) = (.testFlight(output), false)
        }
        return CLIResponse(
            report: report,
            meta: CLIMeta(
                lastSuccessfulSync: data.snapshot.lastSuccessfulSync, generatedAt: now, cliVersion: environment.version,
                isEstimate: isEstimate, appRunning: await appRunning, account: scope.account.name, showsAccount: scope.hasSiblings
            )
        )
    }
}
