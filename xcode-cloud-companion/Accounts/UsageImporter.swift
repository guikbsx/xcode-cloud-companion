import Foundation

/// Which account an export's minutes belong to. Apple's file names no team: the apps it lists are the only clue.
nonisolated enum UsageImportRouting {
    struct Candidate: Sendable, Equatable {
        var id: String
        var productNames: Set<String>
    }

    enum Destination: Sendable, Equatable {
        case account(String)
        /// The export names no app any account knows.
        case unknown
    }

    static func destination(of export: UsageExport, among candidates: [Candidate], selectedID: String) -> Destination {
        let products = Set(export.builds.map(\.product))
        let matches = candidates.map { (id: $0.id, count: products.intersection($0.productNames).count) }.filter { $0.count > 0 }
        if let best = matches.map(\.count).max() {
            // Two teams may name an app alike: the account on screen wins a tie.
            let leaders = matches.filter { $0.count == best }.map(\.id)
            return .account(leaders.contains(selectedID) ? selectedID : leaders[0])
        }
        // Nothing synced yet: a lone account can only be the one.
        if candidates.count == 1, candidates[0].productNames.isEmpty {
            return .account(candidates[0].id)
        }
        return .unknown
    }
}

/// Reads the usage exports for every account: the ones waiting in the folder the user chose, then the new ones as they
/// arrive, and the ones picked by hand. Each is read once and goes to the account whose apps it lists.
final class UsageImporter {
    private let sessions: () -> [AccountSession]
    private let selected: () -> AccountSession?
    private let folder: WatchedFolder
    private let now: () -> Date
    private var watcher: DirectoryWatcher?
    /// The folder being watched, open to the sandbox until `release()`.
    private var active: URL?
    /// The URL whose sandbox access this importer holds.
    private var accessed: URL?
    private var isRunning = false
    private var isScanning = false
    private var needsAnotherScan = false

    init(
        sessions: @escaping () -> [AccountSession],
        selected: @escaping () -> AccountSession?,
        folder: WatchedFolder,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sessions = sessions
        self.selected = selected
        self.folder = folder
        self.now = now
    }

    func start() async {
        isRunning = true
        await follow()
    }

    func stop() {
        isRunning = false
        release()
    }

    /// The user chose another folder, or none: the old one is let go before the new one is read.
    func folderDidChange() async {
        guard isRunning else { return }
        release()
        await follow()
    }

    private func follow() async {
        if active == nil, let url = folder.url {
            accessed = url.startAccessingSecurityScopedResource() ? url : nil
            active = url.resolvingSymlinksInPath()
        }
        await scan()
        guard watcher == nil, let active else { return }
        watcher = DirectoryWatcher(url: active) { [weak self] in
            Task { await self?.scan() }
        }
    }

    private func release() {
        watcher = nil
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        active = nil
    }

    /// An export nobody chose is only imported when its apps say whose it is: otherwise it waits for a sync, or for the user.
    func scan() async {
        guard isRunning else { return }
        guard !isScanning else {
            needsAnotherScan = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            needsAnotherScan = false
            guard let directory = active else { return }
            for file in await UsageExportFile.candidates(in: directory) where !sessions().contains(where: { $0.usageStore.hasImported(file) }) {
                // The folder changed while this one was read: its files are no longer open.
                guard active == directory else { break }
                guard let export = await read(file, reportingTo: selected()) else { continue }
                if case .account(let id) = destination(of: export), let session = sessions().first(where: { $0.id == id }) {
                    await session.usageStore.record(export, from: file)
                }
            }
        } while needsAnotherScan
    }

    /// An export picked by hand goes to the account its apps belong to, and to the one it was picked from when they say
    /// nothing: `shown`, otherwise the account on screen.
    func importFile(at url: URL, shown: AccountSession? = nil) async {
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
        let file = UsageExportFile(url: url, modifiedAt: modifiedAt)
        let shown = shown ?? selected()
        guard let export = await read(file, reportingTo: shown) else { return }
        guard case .account(let id) = destination(of: export, shown: shown), id != shown?.id, let owner = sessions().first(where: { $0.id == id }) else {
            await shown?.usageStore.record(export, from: file)
            return
        }
        guard await owner.usageStore.record(export, from: file) else {
            shown?.usageStore.noteFailure(String(
                localized: "\(url.lastPathComponent) lists the apps of “\(owner.name)”, but its billed minutes could not be saved there. Try again.",
                comment: "A usage export belongs to another account than the one on screen, and that account could not save it. First the file name, then the account name."
            ))
            return
        }
        shown?.usageStore.note(String(
            localized: "\(url.lastPathComponent) lists the apps of “\(owner.name)”: its \(export.builds.count) builds were imported there.",
            comment: "A usage export was imported into another account than the one on screen. First the file name, then the account name."
        ))
    }

    private func read(_ file: UsageExportFile, reportingTo session: AccountSession?) async -> UsageExport? {
        do {
            return try await file.read()
        } catch {
            session?.usageStore.report(error, for: file)
            return nil
        }
    }

    private func destination(of export: UsageExport, shown: AccountSession? = nil) -> UsageImportRouting.Destination {
        let candidates = sessions().map {
            UsageImportRouting.Candidate(id: $0.id, productNames: Set($0.buildStore.snapshot.products.map(\.name)))
        }
        return UsageImportRouting.destination(of: export, among: candidates, selectedID: (shown ?? selected())?.id ?? "")
    }
}
