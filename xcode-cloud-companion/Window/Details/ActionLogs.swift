import AppKit
import Foundation
import Observation

/// Unpacked log archives, one folder per action, in the app's caches: capped in size, the least recently opened going first.
nonisolated struct LogCache: Sendable {
    var directory: URL = AccountPaths.first.logs
    var maximumBytes = 500 * 1024 * 1024

    /// The unpacked folder of an action, if it is still there; opening it again counts as a use.
    @concurrent func folder(actionID: String) async -> URL? {
        guard Self.isSafe(actionID) else { return nil }
        let container = directory.appending(path: actionID)
        let manager = FileManager.default
        guard let name = (try? manager.contentsOfDirectory(atPath: container.path(percentEncoded: false)))?.first(where: { !$0.hasPrefix(".") }) else { return nil }
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: container.path(percentEncoded: false))
        return container.appending(path: name)
    }

    /// Unpacks `archive` next to its final place, moves it in, then makes room. The archive itself is removed either way.
    @concurrent func unpack(_ archive: URL, actionID: String, name: String) async throws -> URL {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: archive) }
        guard Self.isSafe(actionID) else { throw ZipExtractor.Failure.unsafePath(actionID) }
        let staging = directory.appending(path: ".unpacking-\(UUID().uuidString)")
        do {
            try ZipExtractor.extract(archive, to: staging, maximumBytes: maximumBytes)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        let container = directory.appending(path: actionID)
        try? manager.removeItem(at: container)
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        let folder = container.appending(path: Self.folderName(name))
        try manager.moveItem(at: staging, to: folder)
        prune(keeping: actionID)
        return folder
    }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes the folders opened longest ago until the cache fits; the one just unpacked always stays.
    func prune(keeping kept: String) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var folders = names.map { name -> (name: String, used: Date, bytes: Int) in
            let url = directory.appending(path: name)
            let used = (try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date) ?? .distantPast
            return (name, used, Self.size(of: url))
        }
        var total = folders.reduce(0) { $0 + $1.bytes }
        folders.sort { $0.used < $1.used }
        for folder in folders where total > maximumBytes && folder.name != kept {
            try? manager.removeItem(at: directory.appending(path: folder.name))
            total -= folder.bytes
        }
    }

    static func folderName(_ name: String) -> String {
        let cleaned = name.map { "/:\\\0".contains($0) ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "Logs" : String(trimmed.prefix(120))
    }

    private static func size(of folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in files {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private static func isSafe(_ actionID: String) -> Bool {
        !actionID.isEmpty && actionID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

enum LogState: Equatable {
    case idle
    case preparing
    case downloading(fraction: Double?)
    case unpacking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .downloading, .unpacking: true
        case .idle, .failed: false
        }
    }
}

/// Opens an action's logs in the Finder: from the cache when they were fetched before, otherwise downloaded with the same
/// care as an artifact (fresh signed address, trusted hosts only, no token, nothing kept of the address) and unpacked.
@Observable
final class LogOpener {
    private(set) var states: [String: LogState] = [:]
    /// Actions whose files were listed and hold no log archive: their button goes away.
    private(set) var actionsWithoutLogs: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private let client: () async -> AppStoreConnectClient?
    private let fetcher: any ArtifactFetching
    private let cache: LogCache
    private let reveal: (URL) -> Void

    init(
        client: @escaping () async -> AppStoreConnectClient?,
        fetcher: any ArtifactFetching = URLSessionArtifactFetcher(),
        cache: LogCache = LogCache(),
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.client = client
        self.fetcher = fetcher
        self.cache = cache
        self.reveal = reveal
    }

    func state(of actionID: String) -> LogState {
        states[actionID] ?? .idle
    }

    /// A finished action offers its logs unless its files are known and hold none.
    func offersLogs(for action: CIBuildAction, knownArtifacts: [CIArtifact]?) -> Bool {
        guard action.executionProgress == .complete, !actionsWithoutLogs.contains(action.id) else { return false }
        return knownArtifacts.map { Self.logArchive(in: $0) != nil } ?? true
    }

    func start(_ action: CIBuildAction, run: CIBuildRun, knownArtifacts: [CIArtifact]?, title: String) {
        guard tasks[action.id] == nil else { return }
        tasks[action.id] = Task { [self] in
            await open(action, run: run, knownArtifacts: knownArtifacts, title: title)
            tasks[action.id] = nil
        }
    }

    func cancel(_ actionID: String) {
        tasks[actionID]?.cancel()
    }

    /// Where an action's logs are already unpacked, if they are: nothing is downloaded.
    func unpackedFolder(of actionID: String) async -> URL? {
        await cache.folder(actionID: actionID)
    }

    func open(_ action: CIBuildAction, run: CIBuildRun, knownArtifacts: [CIArtifact]?, title: String) async {
        guard let folder = await fetch(action, run: run, knownArtifacts: knownArtifacts, title: title) else { return }
        reveal(folder)
    }

    /// Brings an action's logs into the cache and says where they are, without showing them. The same care as `open`: from
    /// the cache for a finished build, otherwise one archive, picked by `choose` among the action's files.
    func fetch(
        _ action: CIBuildAction, run: CIBuildRun, knownArtifacts: [CIArtifact]?, title: String,
        choose: ([CIArtifact]) -> CIArtifact? = LogOpener.logArchive(in:)
    ) async -> URL? {
        guard !state(of: action.id).isBusy else { return nil }
        // A finished build never changes: what was unpacked once is opened again without a word to Apple.
        if run.executionProgress == .complete, let folder = await cache.folder(actionID: action.id) {
            states[action.id] = .idle
            return folder
        }
        states[action.id] = .preparing
        guard let client = await client() else {
            states[action.id] = .failed(String(localized: "No API key is set up."))
            return nil
        }
        do {
            let artifacts: [CIArtifact]
            if let knownArtifacts {
                artifacts = knownArtifacts
            } else {
                artifacts = try await client.artifacts(buildActionID: action.id)
            }
            guard let archive = choose(artifacts) else {
                actionsWithoutLogs.insert(action.id)
                states[action.id] = .idle
                return nil
            }
            var result = try await fetchFresh(archive, client: client)
            if case .status = result {
                // Refused: the link may have expired. One fresh address, one more try.
                result = try await fetchFresh(archive, client: client)
            }
            switch result {
            case .status(let code):
                states[action.id] = .failed(String(localized: "The link expired or is invalid (HTTP \(code))."))
                return nil
            case .file(let file):
                states[action.id] = .unpacking
                let folder = try await cache.unpack(file, actionID: action.id, name: title)
                try Task.checkCancellation()
                states[action.id] = .idle
                return folder
            }
        } catch is CancellationError {
            states[action.id] = .idle
        } catch let error as URLError where error.code == .cancelled {
            states[action.id] = .idle
        } catch let error as AppStoreConnectError {
            states[action.id] = .failed(error.message)
        } catch let refusal as ArtifactAddress.Refusal {
            states[action.id] = .failed(ArtifactSaver.message(for: refusal))
        } catch is ZipExtractor.Failure {
            states[action.id] = .failed(String(localized: "The log archive can’t be unpacked safely. Save it from the Artifacts tab instead."))
        } catch {
            states[action.id] = .failed(String(localized: "The download could not be completed."))
        }
        return nil
    }

    nonisolated static func logArchive(in artifacts: [CIArtifact]) -> CIArtifact? {
        artifacts.first { $0.fileType == "LOG_BUNDLE" }
    }

    private func fetchFresh(_ artifact: CIArtifact, client: AppStoreConnectClient) async throws -> ArtifactFetchResult {
        let fresh = try await client.artifact(id: artifact.id, buildActionID: artifact.buildActionID)
        let address = try ArtifactAddress.validated(fresh.downloadURL)
        let id = artifact.buildActionID
        states[id] = .downloading(fraction: nil)
        return try await fetcher.fetch(address) { [weak self] fraction in
            Task { @MainActor in
                if case .downloading? = self?.states[id] { self?.states[id] = .downloading(fraction: fraction) }
            }
        }
    }
}
