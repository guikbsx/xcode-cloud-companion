import Foundation
import Observation

/// Whether the API key may write (start builds, pause workflows). Apple does not say which role a key has: the app takes
/// it that the key may, the user says otherwise in Settings › Configuration, and the first 403 from Apple corrects it.
nonisolated enum KeyAccess: String, CaseIterable, Sendable {
    case readOnly
    /// "Read + Build". Named for the first write the app had; it covers pausing a workflow too. The stored value is kept as it is.
    case canLaunch

    /// Every write goes through a confirmation, so the buttons show unless the user, or a 403, said the key cannot.
    static let defaultValue = KeyAccess.canLaunch

    /// Each account says it for its own key; a new key starts from the default.
    static func stored(in defaults: UserDefaults, accountID: String) -> KeyAccess {
        defaults.string(forKey: AccountDefaults.key(AccountDefaults.keyAccess, accountID: accountID)).flatMap(KeyAccess.init(rawValue:)) ?? defaultValue
    }
}

/// How a launch ended. `uncertain` without a run and `unknown` are the two cases where nobody can say whether a build
/// started: every other case is final.
nonisolated enum LaunchOutcome: Equatable, Sendable {
    case started(CIBuildRun)
    /// 403: the key may not start builds (role, team key, or an agreement to accept).
    case notAllowed(message: String)
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String, pointsAtSource: Bool)
    case rateLimited
    case failed(message: String)
    /// Apple accepted the launch (2xx), but nothing of its answer could be read and the build list does not show the
    /// run yet: a build did start, the next sync brings it.
    case accepted
    /// The request may have reached Apple. `found` is a run that looks like the one just asked for; nil when the build
    /// list was read, several times, and shows none.
    case uncertain(found: CIBuildRun?)
    /// The request may have reached Apple, and the build list could not be read either.
    case unknown

    static func classify(_ error: AppStoreConnectError) -> LaunchOutcome? {
        switch error {
        case .forbidden:
            return .notAllowed(message: error.message)
        case .rejected(_, _, let title, let detail, let pointer):
            let words = [title, detail].compactMap { $0?.nilIfBlank }.joined(separator: " ")
            return .refused(message: words.isEmpty ? error.message : words, pointsAtSource: pointer?.contains("sourceBranchOrTag") == true || pointer?.contains("pullRequest") == true)
        case .rateLimited:
            return .rateLimited
        case .unauthorized, .invalidPrivateKey:
            return .failed(message: error.message)
        case .network(let code):
            // These never reached Apple; every other network failure may have.
            let neverSent: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .internationalRoamingOff]
            return neverSent.contains(code) ? .failed(message: error.message) : nil
        case .server, .decoding, .invalidResponse:
            return nil
        }
    }
}

nonisolated extension LaunchOutcome {
    /// For the system log: the case without what it carries.
    var logName: String {
        switch self {
        case .started: "started"
        case .notAllowed: "notAllowed"
        case .refused: "refused"
        case .rateLimited: "rateLimited"
        case .failed: "failed"
        case .accepted: "accepted, not listed yet"
        case .uncertain(let found): found == nil ? "no new build in the list" : "found in the list"
        case .unknown: "list unreadable"
        }
    }
}

/// Starts or rebuilds a run, once. A request is never repeated by the app, whatever came back.
@Observable
final class BuildLauncher {
    private(set) var isLaunching = false
    private(set) var choicesByWorkflow: [String: LaunchChoices] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let now: () -> Date
    private let pause: (Duration) async -> Void

    /// How long to wait before each look at the build list after a launch Apple did not confirm: a run that was just
    /// created is not always listed at once (seen on 2026-10-12: absent half a second after a 201).
    static let lookDelays: [Duration] = [.zero, .seconds(2), .seconds(4), .seconds(8)]

    init(
        client: @escaping () async -> AppStoreConnectClient?, now: @escaping () -> Date = { Date() },
        pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.now = now
        self.pause = pause
    }

    /// What the workflow's repository offers to launch on, read once per session. The pull requests are a second request:
    /// when it fails, the branches and tags still show.
    func choices(for workflowID: String) async -> LaunchChoices? {
        if let known = choicesByWorkflow[workflowID] { return known }
        guard let client = await client(),
              let repository = try? await client.repositoryID(workflowID: workflowID),
              let references = try? await client.gitReferences(repositoryID: repository)
        else { return nil }
        let pullRequests = try? await client.pullRequests(repositoryID: repository)
        let choices = LaunchChoices(references: references, pullRequests: pullRequests)
        choicesByWorkflow[workflowID] = choices
        return choices
    }

    func launch(_ request: BuildRunRequest, productID: String, workflowName: String?) async -> LaunchOutcome {
        // A second tap while the first is in flight must not start a second build.
        guard !isLaunching else { return .failed(message: String(localized: "A launch is already in progress.")) }
        isLaunching = true
        defer { isLaunching = false }
        guard let client = await client() else { return .failed(message: String(localized: "No API key is set up.")) }

        let attemptStart = now()
        do {
            let run = try await client.startBuildRun(request, productID: productID, workflowName: workflowName)
            return .started(run)
        } catch {
            if let outcome = LaunchOutcome.classify(error) { return outcome }
            // The request is never sent again: the build list tells whether it started, before anyone tries again.
            let look = await lookForRun(request, productID: productID, since: attemptStart, client: client)
            let outcome: LaunchOutcome
            // A body that does not decode came with a 2xx: Apple did start the build.
            if case .decoding = error {
                outcome = switch look {
                case .found(let run): .started(run)
                case .absent, .unreadable: .accepted
                }
            } else {
                outcome = switch look {
                case .found(let run): .uncertain(found: run)
                case .absent: .uncertain(found: nil)
                case .unreadable: .unknown
                }
            }
            LaunchLog.unconfirmed(error, outcome: outcome.logName)
            return outcome
        }
    }

    private enum Look {
        case found(CIBuildRun)
        /// The list was read and shows no run that looks like ours.
        case absent
        case unreadable
    }

    private func lookForRun(_ request: BuildRunRequest, productID: String, since attempt: Date, client: AppStoreConnectClient) async -> Look {
        var wasRead = false
        for delay in Self.lookDelays {
            if delay > .zero { await pause(delay) }
            do {
                let latest = try await client.latestBuildRun(workflowID: request.workflowID, productID: productID)
                wasRead = true
                if let latest, Self.looksLikeOurs(latest, since: attempt) { return .found(latest) }
            } catch {
                // Asking again after a 429 only lengthens the wait Apple imposes.
                if error == .rateLimited { break }
            }
        }
        return wasRead ? .absent : .unreadable
    }

    /// A run created after the attempt began, started by hand, counts as the one that was asked for.
    static func looksLikeOurs(_ run: CIBuildRun, since attempt: Date) -> Bool {
        guard let created = run.createdDate, created >= attempt.addingTimeInterval(-60) else { return false }
        return run.startReason == nil || run.startReason == "MANUAL" || run.startReason == "MANUAL_REBUILD"
    }
}
