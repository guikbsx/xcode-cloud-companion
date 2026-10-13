import Foundation

nonisolated enum AppIPCRefresh {
    /// Mirrors the app's own rule: a sync this recent is not asked again.
    static let recentSync: TimeInterval = 30
}

/// What `cumulus run` worked out from the cache, before the person confirms and the app is asked.
nonisolated struct LaunchPlan: Equatable, Sendable {
    var request: IPCLaunchRequest
    var workflowName: String
    var appName: String
    var accountName: String
    var showsAccount: Bool
}

/// The command's line to the running app: is it there, start it, ask it for a sync, a build's details, or a build.
nonisolated struct CLIAppLink: Sendable {
    static let defaultWait: TimeInterval = 120
    static let detailsTimeout: TimeInterval = 60

    let environment: CLIEnvironment
    /// The account the command answers for; the app's own selection when nil.
    var accountID: String?

    private var client: IPCClient? {
        environment.socketPath.map(IPCClient.init(path:))
    }

    func isAppRunning() async -> Bool {
        await client?.ping() != nil
    }

    /// Asks the app to fetch a finished build's details into the cache; false when it is not running or could not.
    func loadDetails(buildRunID: String) async -> Bool {
        guard let client, await client.ping() != nil else { return false }
        let request = IPCRequest(id: UUID().uuidString, method: IPCMethod.loadDetails, params: IPCRequest.Params(buildRunID: buildRunID))
        return (try? await client.send(request, timeout: Self.detailsTimeout))?.loaded ?? false
    }

    /// Starts the app when it is not running, and waits for its socket; true when it had to be started.
    private func startAppIfNeeded(_ client: IPCClient) async throws(CLIFailure) -> Bool {
        guard await client.ping(timeout: 0.5) == nil else { return false }
        guard await environment.launchApp() else { throw CLIFailure.appUnreachable }
        let deadline = Date().addingTimeInterval(environment.launchPatience)
        while await client.ping(timeout: 0.5) == nil {
            guard Date() < deadline else { throw CLIFailure.appUnreachable }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// Asks the app to start a build; the app's answer, or why it would not.
    func launch(_ request: IPCLaunchRequest) async throws(CLIFailure) -> (result: IPCResult, appLaunched: Bool) {
        guard let client else { throw CLIFailure.appUnreachable }
        let launched = try await startAppIfNeeded(client)
        let ipc = IPCRequest(id: UUID().uuidString, method: IPCMethod.launch, params: request.params)
        let result: IPCResult
        do {
            result = try await client.send(ipc, timeout: Self.launchTimeout)
        } catch .timedOut {
            throw CLIFailure(code: .timedOut, message: "The app did not answer in time.", suggestions: ["Run 'cumulus builds --limit 1' to see whether a build started before trying again."])
        } catch {
            throw CLIFailure.appUnreachable
        }
        guard result.launched == true else { throw Self.failure(for: result) }
        return (result, launched)
    }

    static let launchTimeout: TimeInterval = 90

    static func failure(for result: IPCResult) -> CLIFailure {
        let detail = result.message.map { " \($0)" } ?? ""
        switch result.reason {
        case IPCLaunchReason.noCredentials?:
            return CLIFailure(code: .noCache, message: "Cumulus has no App Store Connect API key for this account.", suggestions: ["Open the Cumulus app and add your key in Settings."])
        case IPCLaunchReason.unknownAccount?:
            return CLIFailure(code: .notFound, message: "Cumulus no longer has this account.", suggestions: ["Run 'cumulus accounts' to list the accounts."])
        case IPCLaunchReason.notAllowed?:
            return CLIFailure(code: .notAllowed, message: "The key may not start builds.\(detail)", suggestions: ["Set the key to “Read + Build” in Cumulus › Settings › Accounts, if its role allows it."])
        case IPCLaunchReason.capReached?:
            return CLIFailure(code: .rateLimited, message: "Cumulus refused: agents already started their share of builds this hour.\(detail)", suggestions: ["Ask the user to start the build from the app, or try again later."])
        case IPCLaunchReason.rateLimited?:
            return CLIFailure(code: .rateLimited, message: "Apple’s hourly request limit is reached. Nothing was started.", suggestions: ["Try again later."])
        case IPCLaunchReason.unknownWorkflow?:
            return CLIFailure(code: .notFound, message: "The app does not know this workflow any more.", suggestions: ["Run 'cumulus refresh --wait', then 'cumulus workflows'."])
        case IPCLaunchReason.unknownReference?:
            return CLIFailure(code: .notFound, message: "No such branch, tag or open pull request.\(detail)", suggestions: ["Check the name, or pass another source."])
        case IPCLaunchReason.refused?:
            return CLIFailure(code: .refused, message: "Apple refused to start the build.\(detail)", suggestions: ["The workflow may be paused, or none of its manual start conditions covers this source."])
        case IPCLaunchReason.uncertain?:
            return CLIFailure(code: .internal, message: "Apple did not confirm the launch.\(detail)", suggestions: ["Run 'cumulus refresh --wait', then 'cumulus builds --limit 1' before trying again: a build may have started."])
        case IPCLaunchReason.unknown?:
            return CLIFailure(code: .internal, message: "Whether a build started is not known.\(detail)", suggestions: ["Do not launch again yet: run 'cumulus refresh --wait', then 'cumulus builds --limit 1' to see whether it started."])
        default:
            return CLIFailure(code: .internal, message: "The build could not be started.\(detail)")
        }
    }

    func refresh(wait: Bool, timeout: TimeInterval?) async throws(CLIFailure) -> (output: RefreshOutput, lastSuccessfulSync: Date?) {
        guard let client else { throw CLIFailure.appUnreachable }
        let launched = try await startAppIfNeeded(client)
        let request = IPCRequest(id: UUID().uuidString, method: IPCMethod.refresh, params: IPCRequest.Params(wait: wait, accountID: accountID))
        let result: IPCResult
        do {
            result = try await client.send(request, timeout: wait ? timeout ?? Self.defaultWait : 10)
        } catch .timedOut {
            throw CLIFailure(
                code: .timedOut, message: "The sync did not end in time.",
                suggestions: ["It goes on in the app: run 'cumulus status' in a moment, or wait longer with --timeout."]
            )
        } catch {
            throw CLIFailure.appUnreachable
        }
        if result.reason == IPCRefreshReason.noCredentials {
            throw CLIFailure(
                code: .noCache, message: "Cumulus has no App Store Connect API key yet.",
                suggestions: ["Open the Cumulus app and add your key in Settings."]
            )
        }
        if result.reason == IPCRefreshReason.unknownAccount {
            throw CLIFailure(
                code: .notFound, message: "Cumulus no longer has this account.",
                suggestions: ["Run 'cumulus accounts' to list the accounts."]
            )
        }
        let output = RefreshOutput(accepted: result.accepted ?? false, reason: result.reason, outcome: result.outcome, waited: wait, appLaunched: launched)
        return (output, result.lastSuccessfulSync)
    }
}
