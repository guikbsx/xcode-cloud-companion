import Foundation

nonisolated enum CumulusCLI {
    static func run(arguments: [String], environment: CLIEnvironment) async -> CLIResult {
        let invocation: CLIInvocation
        do {
            invocation = try CLIParser.parse(arguments, now: environment.now())
        } catch {
            return failure(error, format: nil, environment: environment)
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
            return CLIResult(stdout: verbose ? line + (await cacheInfo(environment)) : line)
        case .cacheInfo:
            return CLIResult(stdout: await cacheInfo(environment))
        case .query(let query):
            do {
                let response = try await CLIQueryRunner(environment: environment).run(query)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .refresh(let wait, let timeout):
            do {
                let response = try await CLIQueryRunner(environment: environment).refresh(wait: wait, timeout: timeout)
                return CLIResult(stdout: render(response, format: invocation.format, environment: environment))
            } catch {
                return failure(error, format: invocation.format, environment: environment)
            }
        case .open(let reference):
            do throws(CLIFailure) {
                let snapshot = try await CLIData.load(from: environment.directory, includingUsage: false).snapshot
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

    private static func cacheInfo(_ environment: CLIEnvironment) async -> String {
        let fileURL = environment.directory.appending(path: "BuildCache.json")
        var lines = ["cache: \(fileURL.path(percentEncoded: false))"]
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

    /// Asks the app for a sync; once it has waited for it, the answer carries the status read from the fresh cache.
    func refresh(wait: Bool, timeout: TimeInterval?) async throws(CLIFailure) -> CLIResponse {
        let (refreshed, lastSuccessfulSync) = try await CLIAppLink(environment: environment).refresh(wait: wait, timeout: timeout)
        var output = refreshed
        var meta = CLIMeta(lastSuccessfulSync: lastSuccessfulSync, generatedAt: environment.now(), cliVersion: environment.version, appRunning: true)
        if wait, let status = try? await run(.status), case .status(let statusOutput) = status.report {
            output.status = statusOutput
            meta.lastSuccessfulSync = status.meta.lastSuccessfulSync ?? lastSuccessfulSync
            meta.isEstimate = status.meta.isEstimate
        }
        return CLIResponse(report: .refresh(output), meta: meta)
    }

    func run(_ query: CLIQuery) async throws(CLIFailure) -> CLIResponse {
        let now = environment.now()
        let link = CLIAppLink(environment: environment)
        async let appRunning = link.isAppRunning()
        let wantsWorkflowDetails = if case .workflows = query { true } else { false }
        let data = try await CLIData.load(from: environment.directory, includingUsage: true, includingWorkflowDetails: wantsWorkflowDetails)
        let builder = CLIReportBuilder(data: data, now: now, calendar: environment.calendar)
        let report: CLIReport
        let isEstimate: Bool
        switch query {
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
            let cache = BuildExtrasCache(directory: environment.directory.appending(path: "BuildDetails"))
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
        }
        return CLIResponse(
            report: report,
            meta: CLIMeta(
                lastSuccessfulSync: data.snapshot.lastSuccessfulSync, generatedAt: now, cliVersion: environment.version,
                isEstimate: isEstimate, appRunning: await appRunning
            )
        )
    }
}
