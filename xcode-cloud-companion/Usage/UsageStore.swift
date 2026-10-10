import Foundation
import Observation

nonisolated struct UsageLedgerStore: Sendable {
    var fileURL: URL = AccountPaths.first.usageLedger

    @concurrent func load() async -> UsageLedger? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(UsageLedger.self, from: data)
    }

    @concurrent func save(_ ledger: UsageLedger) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: fileURL, options: [.atomic])
    }
}

nonisolated struct UsageExportFile: Sendable {
    let url: URL
    let modifiedAt: Date

    /// Usage exports sitting in `directory`, newest last so the latest values win.
    @concurrent static func candidates(in directory: URL) async -> [UsageExportFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url -> UsageExportFile? in
            guard UsageExportParser.isUsageExport(fileName: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate
            else { return nil }
            return UsageExportFile(url: url, modifiedAt: modifiedAt)
        }
        .sorted { $0.modifiedAt < $1.modifiedAt }
    }

    @concurrent func read() async throws(UsageImportError) -> UsageExport {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try UsageExportParser.parse(data, fileName: url.lastPathComponent)
    }
}

/// Billed minutes imported from App Store Connect's usage exports.
@Observable
final class UsageStore {
    private(set) var ledger = UsageLedger()
    private(set) var lastImportMessage: String?
    private(set) var lastImportFailed = false

    private let ledgerStore: UsageLedgerStore
    private let watchedDirectory: URL?
    private let now: () -> Date
    private var watcher: DirectoryWatcher?
    private var isScanning = false

    init(
        ledgerStore: UsageLedgerStore = UsageLedgerStore(),
        watchedDirectory: URL? = .downloadsDirectory,
        now: @escaping () -> Date = { Date() }
    ) {
        self.ledgerStore = ledgerStore
        self.watchedDirectory = watchedDirectory?.resolvingSymlinksInPath()
        self.now = now
    }

    /// Loads the ledger, imports exports already waiting, then imports new ones as they arrive.
    func start() async {
        if let saved = await ledgerStore.load() {
            ledger = saved
        }
        await scanWatchedDirectory()
        guard let watchedDirectory, watcher == nil else { return }
        watcher = DirectoryWatcher(url: watchedDirectory) { [weak self] in
            Task { await self?.scanWatchedDirectory() }
        }
    }

    /// Forgets every billed minute, but remembers the exports already seen so the folder watcher does not bring them back.
    func reset() async {
        ledger = UsageLedger(importedFiles: ledger.importedFiles)
        lastImportMessage = nil
        lastImportFailed = false
        try? await ledgerStore.save(ledger)
    }

    func stop() {
        watcher = nil
    }

    func scanWatchedDirectory() async {
        guard let watchedDirectory, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        for file in await UsageExportFile.candidates(in: watchedDirectory)
        where !ledger.hasImported(fileName: file.url.lastPathComponent, modifiedAt: file.modifiedAt) {
            await importFile(file)
        }
    }

    /// For an export picked by hand, outside the watched folder.
    func importFile(at url: URL) async {
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
        await importFile(UsageExportFile(url: url, modifiedAt: modifiedAt))
    }

    private func importFile(_ file: UsageExportFile) async {
        do {
            await record(try await file.read(), from: file)
        } catch {
            report(error, for: file)
        }
    }

    func hasImported(_ file: UsageExportFile) -> Bool {
        ledger.hasImported(fileName: file.url.lastPathComponent, modifiedAt: file.modifiedAt)
    }

    /// Adds an export already read: with several accounts, it is read once and handed to the account its apps belong to.
    func record(_ export: UsageExport, from file: UsageExportFile) async {
        ledger.merge(export, fileName: file.url.lastPathComponent, modifiedAt: file.modifiedAt, importedAt: now())
        try? await ledgerStore.save(ledger)
        lastImportFailed = false
        lastImportMessage = String(localized: "Imported \(export.builds.count) builds from \(file.url.lastPathComponent).")
    }

    func report(_ error: UsageImportError, for file: UsageExportFile) {
        lastImportFailed = true
        lastImportMessage = "\(file.url.lastPathComponent): \(error.message)"
    }

    /// Says where an export went when it was not into this account.
    func note(_ message: String) {
        lastImportFailed = false
        lastImportMessage = message
    }
}
