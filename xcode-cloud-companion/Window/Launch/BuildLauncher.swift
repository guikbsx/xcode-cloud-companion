import Foundation
import Observation

/// What the user declared about the API key: whether it may start builds. Apple does not say which role a key has,
/// so the app asks, and corrects itself the first time Apple answers 403.
nonisolated enum KeyAccess: String, CaseIterable, Sendable {
    case readOnly
    case canLaunch

    static let defaultsKey = "keyAccess"

    static func current(in defaults: UserDefaults = .standard) -> KeyAccess {
        defaults.string(forKey: defaultsKey).flatMap(KeyAccess.init(rawValue:)) ?? .readOnly
    }
}

/// How a launch ended. Only `uncertain` means nobody knows: every other case is final.
nonisolated enum LaunchOutcome: Equatable, Sendable {
    case started(CIBuildRun)
    /// 403: the key may not start builds (role, team key, or an agreement to accept).
    case notAllowed(message: String)
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String, pointsAtSource: Bool)
    case rateLimited
    case failed(message: String)
    /// The request may have reached Apple. `found` is a run that looks like the one just asked for, when the list shows one.
    case uncertain(found: CIBuildRun?)

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

/// Starts or rebuilds a run, once. A request is never repeated by the app, whatever came back.
@Observable
final class BuildLauncher {
    private(set) var isLaunching = false
    private(set) var referencesByWorkflow: [String: [GitReference]] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let now: () -> Date

    init(client: @escaping () async -> AppStoreConnectClient?, now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    func references(for workflowID: String) async -> [GitReference]? {
        if let known = referencesByWorkflow[workflowID] { return known }
        guard let client = await client(),
              let repository = try? await client.repositoryID(workflowID: workflowID),
              let found = try? await client.gitReferences(repositoryID: repository)
        else { return nil }
        referencesByWorkflow[workflowID] = found
        return found
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
            // Ambiguous: the build list tells whether it started, before anyone tries again.
            let latest = try? await client.latestBuildRun(workflowID: request.workflowID, productID: productID)
            return .uncertain(found: latest.flatMap { Self.looksLikeOurs($0, since: attemptStart) ? $0 : nil })
        }
    }

    /// A run created after the attempt began, started by hand, counts as the one that was asked for.
    static func looksLikeOurs(_ run: CIBuildRun, since attempt: Date) -> Bool {
        guard let created = run.createdDate, created >= attempt.addingTimeInterval(-60) else { return false }
        return run.startReason == nil || run.startReason == "MANUAL" || run.startReason == "MANUAL_REBUILD"
    }
}
