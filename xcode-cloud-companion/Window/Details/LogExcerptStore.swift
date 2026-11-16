import Foundation
import Observation

/// Which action's log the excerpt comes from: the first action of the build that failed.
nonisolated enum LogExcerptTarget {
    static func action(in actions: [CIBuildAction]) -> CIBuildAction? {
        BuildDetailModel.ordered(actions).first {
            $0.executionProgress == .complete && ($0.completionStatus == .failed || $0.completionStatus == .errored)
        }
    }
}

/// What the “Log Excerpt” card knows, by action. Opening a build asks Apple for nothing: the excerpt is read from a log that
/// is already unpacked on this Mac. Only the card's button downloads, with the rules of `LogOpener` (a fresh signed address,
/// no token, the cache's cap) and not while the hour's requests are nearly spent.
@Observable
final class LogExcerptStore {
    enum Outcome: Equatable {
        case found(LogExcerpt)
        case nothing
        /// The log is not unpacked on this Mac.
        case notOnThisMac
        /// The action left no log archive.
        case noLog
        case failed(String)

        var isRead: Bool {
            switch self {
            case .found, .nothing: true
            case .notOnThisMac, .noLog, .failed: false
            }
        }
    }

    private(set) var outcomes: [String: Outcome] = [:]
    private(set) var working: Set<String> = []
    private let logOpener: LogOpener
    private let budget: () async -> RateLimit?
    private let search: @Sendable (URL, [LogLocationHint]) async -> LogExcerptOutcome

    init(
        logOpener: LogOpener, budget: @escaping () async -> RateLimit?,
        search: @escaping @Sendable (URL, [LogLocationHint]) async -> LogExcerptOutcome = { await LogExcerptSearch.search(in: $0, hints: $1) }
    ) {
        self.logOpener = logOpener
        self.budget = budget
        self.search = search
    }

    func outcome(for actionID: String) -> Outcome? {
        outcomes[actionID]
    }

    func isWorking(_ actionID: String) -> Bool {
        working.contains(actionID)
    }

    /// Reads the excerpt when the action's log is already unpacked; otherwise says it is not. Never a request.
    func load(_ action: CIBuildAction, hints: [LogLocationHint]) async {
        guard outcomes[action.id]?.isRead != true, !working.contains(action.id) else { return }
        guard let folder = await logOpener.unpackedFolder(of: action.id) else {
            if outcomes[action.id] == nil { outcomes[action.id] = .notOnThisMac }
            return
        }
        working.insert(action.id)
        defer { working.remove(action.id) }
        outcomes[action.id] = await read(folder, hints: hints)
    }

    /// The card's button: downloads the log of the action if it is not here, then reads it.
    func fetchAndLoad(
        _ action: CIBuildAction, run: CIBuildRun, title: String, knownArtifacts: [CIArtifact]?, signals: LogArchiveChoice.Signals, hints: [LogLocationHint]
    ) async {
        guard !working.contains(action.id) else { return }
        if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining {
            outcomes[action.id] = .failed(String(localized: "Apple’s hourly request limit is nearly spent: the log waits for the next hour."))
            return
        }
        working.insert(action.id)
        defer { working.remove(action.id) }
        let folder = await logOpener.fetch(action, run: run, knownArtifacts: knownArtifacts, title: title) { LogArchiveChoice.pick(from: $0, signals: signals) }
        guard let folder else {
            switch logOpener.state(of: action.id) {
            case .failed(let message): outcomes[action.id] = .failed(message)
            default: if logOpener.actionsWithoutLogs.contains(action.id) { outcomes[action.id] = .noLog }
            }
            return
        }
        outcomes[action.id] = await read(folder, hints: hints)
    }

    /// The excerpt to attach to the text for an AI: only when the log is already here. Never a request.
    func excerptForPrompt(actions: [CIBuildAction], extras: BuildExtras?) async -> (actionName: String, excerpt: LogExcerpt)? {
        guard let action = LogExcerptTarget.action(in: actions) else { return nil }
        if outcomes[action.id]?.isRead != true {
            await load(action, hints: LogLocationHint.hints(issues: extras?.issuesByAction[action.id] ?? [], tests: extras?.testsByAction[action.id] ?? []))
        }
        guard case .found(let excerpt)? = outcomes[action.id] else { return nil }
        return ((action.name ?? action.actionType?.rawValue)?.nilIfBlank ?? "action", excerpt)
    }

    private func read(_ folder: URL, hints: [LogLocationHint]) async -> Outcome {
        switch await search(folder, hints) {
        case .found(let excerpt): .found(excerpt)
        case .nothing: .nothing
        }
    }
}
