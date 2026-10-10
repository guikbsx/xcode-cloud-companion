import Foundation

nonisolated enum AppIPCRefresh {
    /// Mirrors the app's own rule: a sync this recent is not asked again.
    static let recentSync: TimeInterval = 30
}

/// The command's line to the running app: is it there, start it, ask it for a sync or for a build's details.
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

    func refresh(wait: Bool, timeout: TimeInterval?) async throws(CLIFailure) -> (output: RefreshOutput, lastSuccessfulSync: Date?) {
        guard let client else { throw CLIFailure.appUnreachable }
        var launched = false
        if await client.ping(timeout: 0.5) == nil {
            guard await environment.launchApp() else { throw CLIFailure.appUnreachable }
            launched = true
            let deadline = Date().addingTimeInterval(environment.launchPatience)
            while await client.ping(timeout: 0.5) == nil {
                guard Date() < deadline else { throw CLIFailure.appUnreachable }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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
