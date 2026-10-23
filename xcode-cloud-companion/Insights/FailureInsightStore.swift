import Foundation
import Observation

/// Refuses every request, for the places where the real model must never be asked (tests).
nonisolated struct UnavailableInsightGenerator: FailureInsightGenerating {
    func generate(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) async throws -> RawFailureInsight {
        throw FailureInsightError.unavailable("not asked")
    }
}

/// The insights of one account's failed builds. An insight is made once per build and language, then kept on disk; the
/// window and, later, the notifications ask for it here.
@Observable
final class FailureInsightStore {
    private(set) var records: [String: FailureInsightRecord] = [:]
    private(set) var loadingRunIDs: Set<String> = []

    /// Whether the feature is open for this account right now: the model, the setting and Cumulus Pro.
    @ObservationIgnored var isOpen: () -> Bool = { true }

    private let buildStore: BuildStore
    private let extrasStore: BuildExtrasStore
    private let cache: FailureInsightCache
    private let service: FailureInsightService
    private let language: () -> FailureInsightLanguage

    init(
        buildStore: BuildStore, extrasStore: BuildExtrasStore, cache: FailureInsightCache, service: FailureInsightService,
        language: @escaping () -> FailureInsightLanguage = { .current }
    ) {
        self.buildStore = buildStore
        self.extrasStore = extrasStore
        self.cache = cache
        self.service = service
        self.language = language
    }

    /// What is known now; asks for nothing.
    func insight(for runID: String) -> FailureInsightRecord? {
        records[runID]
    }

    func isLoading(_ runID: String) -> Bool {
        loadingRunIDs.contains(runID)
    }

    /// Makes the insight of a failed build known: from disk, else from the model once the build's issues and test results
    /// are read. A build whose data cannot be read is left alone and tried again at the next opening.
    func load(_ run: CIBuildRun) async {
        guard BuildFailurePrompt.isOffered(for: run), records[run.id] == nil, !loadingRunIDs.contains(run.id), isOpen() else { return }
        loadingRunIDs.insert(run.id)
        defer { loadingRunIDs.remove(run.id) }

        let language = language()
        if let cached = await cache.load(runID: run.id, language: language) {
            records[run.id] = cached
            return
        }
        let prompt = await BuildFailureCopier(buildStore: buildStore, extrasStore: extrasStore).loadedPrompt(for: run)
        guard !Task.isCancelled, isOpen(), let input = FailureInsightInput(prompt: prompt) else { return }

        let outcome = await service.insight(for: input, language: language)
        let record = FailureInsightRecord(category: input.category, insight: outcome.insight, failedTests: prompt.failedTests)
        records[run.id] = record
        await cache.save(record, runID: run.id, language: language)
    }

    /// Brings into memory the records already on disk for these builds, while the function is open. It asks the model for
    /// nothing and reads no issue and no test result: a build without a record stays without one.
    func loadCached(runIDs: [String]) async {
        guard isOpen() else { return }
        let language = language()
        for id in runIDs where records[id] == nil {
            if let cached = await cache.load(runID: id, language: language), records[id] == nil {
                records[id] = cached
            }
        }
    }

    /// Forgets what is in memory and on disk, when the account loses its key.
    func reset() async {
        records = [:]
        await cache.deleteAll()
    }
}
