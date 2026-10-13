import Foundation

/// How many builds agents may start in an hour, per account: an agent in a loop must not spend the plan.
nonisolated enum AgentLaunchGate {
    static let cap = 3
    static let window: TimeInterval = 3600

    /// Whether one more launch is allowed given the earlier ones, and when the next will be if not.
    static func allows(_ launches: [Date], now: Date, cap: Int = cap, window: TimeInterval = window) -> (allowed: Bool, nextAt: Date?) {
        let recent = launches.filter { now.timeIntervalSince($0) < window }.sorted()
        guard recent.count >= cap else { return (true, nil) }
        return (false, recent[recent.count - cap].addingTimeInterval(window))
    }
}

/// Starts a build asked for over the socket: the window's own `BuildLauncher`, behind the key's access and the cap. The
/// request is never repeated; a 403 puts the key in read-only mode as it does in the window.
@MainActor
final class AgentLaunchService {
    private let accounts: AccountsModel
    private let preferences: NotificationPreferences
    private let notify: ([LocalNotification]) async -> Void
    private let now: () -> Date
    private var launches: [String: [Date]] = [:]

    init(accounts: AccountsModel, preferences: NotificationPreferences, notify: @escaping ([LocalNotification]) async -> Void, now: @escaping () -> Date = { Date() }) {
        self.accounts = accounts
        self.preferences = preferences
        self.notify = notify
        self.now = now
    }

    func launch(_ request: IPCLaunchRequest) async -> IPCResult {
        // Asked of the app's own store: the shared file the command reads can be edited by hand.
        guard accounts.pro?.allows(.commandLine) ?? true else { return refusal(IPCLaunchReason.proRequired) }
        await accounts.whenReady()
        guard let session = request.accountID.map({ accounts.session(id: $0) }) ?? accounts.selected else {
            return refusal(request.accountID == nil ? IPCLaunchReason.noCredentials : IPCLaunchReason.unknownAccount)
        }
        await session.settings.load()
        guard session.settings.hasStoredKey else { return refusal(IPCLaunchReason.noCredentials) }
        guard session.settings.keyAccess == .canLaunch else {
            return refusal(IPCLaunchReason.notAllowed, message: String(localized: "The key is set to read-only in Cumulus › Settings › Accounts."))
        }
        let gate = AgentLaunchGate.allows(launches[session.id] ?? [], now: now())
        guard gate.allowed else {
            let next = gate.nextAt.map { UsageFormat.moment($0) } ?? ""
            return refusal(IPCLaunchReason.capReached, message: String(localized: "Agents already started \(AgentLaunchGate.cap) builds in the last hour; the next is possible at \(next)."))
        }
        await session.buildStore.loadCacheIfNeeded()
        let snapshot = session.buildStore.snapshot
        guard let workflow = snapshot.workflow(id: request.workflowID),
              let productID = workflow.productID ?? snapshot.runs.first(where: { $0.workflowID == workflow.id })?.productID
        else { return refusal(IPCLaunchReason.unknownWorkflow) }

        let launcher = session.windowStores.launcher
        guard let choices = await launcher.choices(for: workflow.id) else {
            return refusal(IPCLaunchReason.failed, message: String(localized: "The workflow’s branches could not be read from App Store Connect."))
        }
        guard let source = Self.source(for: request.source, in: choices) else {
            return refusal(IPCLaunchReason.unknownReference, message: String(localized: "No \(request.source.label) in the repository, or the pull request is closed."))
        }
        let outcome = await launcher.launch(.launch(workflowID: workflow.id, source: source, clean: request.clean), productID: productID, workflowName: workflow.name)
        switch outcome {
        case .started(let run), .uncertain(let run?):
            launches[session.id, default: []].append(now())
            session.buildStore.insertStarted(run)
            await announce(run, workflow: workflow, source: request.source, session: session)
            return IPCResult(launched: true, buildRunID: run.id, buildNumber: run.number)
        case .notAllowed(let message):
            session.settings.keyAccess = .readOnly
            return refusal(IPCLaunchReason.notAllowed, message: message)
        case .refused(let message, _):
            return refusal(IPCLaunchReason.refused, message: message)
        case .rateLimited:
            return refusal(IPCLaunchReason.rateLimited)
        case .failed(let message):
            return refusal(IPCLaunchReason.failed, message: message)
        case .accepted:
            launches[session.id, default: []].append(now())
            Task { await session.buildStore.refreshNow() }
            return IPCResult(launched: true, message: String(localized: "Apple accepted the launch; the build is not in the list yet."))
        case .uncertain(nil):
            launches[session.id, default: []].append(now())
            return refusal(IPCLaunchReason.uncertain, message: String(localized: "Apple did not confirm the launch, and the build list shows no new build."))
        case .unknown:
            launches[session.id, default: []].append(now())
            return refusal(IPCLaunchReason.unknown, message: String(localized: "Apple did not confirm the launch, and the build list could not be read: a build may have started."))
        }
    }

    static func source(for wanted: IPCLaunchRequest.Source, in choices: LaunchChoices) -> LaunchSource? {
        switch wanted {
        case .branch(let name): choices.branches.first { $0.name == name }.map { .gitReference(id: $0.id) }
        case .tag(let name): choices.tags.first { $0.name == name }.map { .gitReference(id: $0.id) }
        case .pullRequest(let number): choices.pullRequests?.first { $0.number == number }.map { .pullRequest(id: $0.id) }
        }
    }

    /// The user learns at once that an agent spent minutes, wherever they are.
    private func announce(_ run: CIBuildRun, workflow: CIWorkflow, source: IPCLaunchRequest.Source, session: AccountSession) async {
        guard preferences.builds.agentLaunches else { return }
        let product = session.buildStore.snapshot.products.first { $0.id == run.productID }
        let number = run.number.map { "#\($0)" } ?? ""
        await notify([
            LocalNotification(
                id: "agent-launch-\(run.id)",
                title: String(localized: "Build started by an agent"),
                subtitle: accounts.hasSeveral ? session.name : nil,
                body: UsageFormat.dotted([[product?.displayName, number].compactMap(\.self).joined(separator: " "), workflow.name, source.label]),
                url: CumulusURL.build(id: run.id),
                thread: run.productID
            ),
        ])
    }

    private func refusal(_ reason: String, message: String? = nil) -> IPCResult {
        IPCResult(reason: reason, launched: false, message: message)
    }
}
