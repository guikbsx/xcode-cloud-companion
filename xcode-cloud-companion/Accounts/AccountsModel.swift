import Foundation
import Observation

/// Turns an installation from before accounts existed into the first account: its preferences take the account's
/// prefix and its caches move into the account's folders. The keychain item stays where it is, it already carries the
/// first account's id.
nonisolated struct AccountMigration: Sendable {
    /// Where the caches were before the app group existed; they go through the group container on their way.
    var legacySupport: URL?
    var supportRoot: URL = SharedContainer.applicationSupport
    var cachesRoot: URL = .cachesDirectory
    var paths = AccountPaths.first

    func adoptPreferences(in defaults: UserDefaults) {
        AccountDefaults.adoptLegacyValues(in: defaults)
    }

    func moveCaches() async {
        if let legacySupport {
            await CacheMigration(source: legacySupport, destination: supportRoot).run()
        }
        await CacheMigration(source: supportRoot, destination: paths.support, itemNames: CacheMigration.itemNames + ["UsagePlan.json"]).run()
        await CacheMigration(source: cachesRoot, destination: paths.caches, itemNames: ["AppIcons", "Logs"]).run()
    }
}

/// Every account the app follows. All of them sync all the time, each with its own key; one is selected, and it is the
/// one the menu, the window and the `cumulus` command show.
@Observable
final class AccountsModel {
    private(set) var sessions: [AccountSession]
    private(set) var selectedID: String
    /// Why the last removal did not happen (the keychain refused), for Settings to show.
    private(set) var removalError: String?
    /// Called after each successful sync of an account, with its snapshot before and after.
    @ObservationIgnored var onSync: ((_ session: AccountSession, _ previous: BuildSnapshot, _ current: BuildSnapshot) -> Void)?
    /// Called as soon as another account is on screen: what was selected in the window belonged to the one before.
    @ObservationIgnored var onSelectionChange: (() -> Void)?

    private let registryStore: AccountRegistryStore
    private let migration: AccountMigration?
    private let makeSession: (Account) -> AccountSession
    @ObservationIgnored private lazy var importer = UsageImporter(
        sessions: { [weak self] in self?.sessions ?? [] },
        selected: { [unowned self] in selected },
        watchedDirectory: watchedDirectory
    )
    private let watchedDirectory: URL?
    private var startup: Task<Void, Never>?
    private var registryWrite: Task<Void, Never>?
    private var isRunning = false
    private var windowIsOpen = false

    init(
        registryStore: AccountRegistryStore = AccountRegistryStore(),
        defaults: UserDefaults = .standard,
        migration: AccountMigration? = AccountMigration(),
        watchedDirectory: URL? = .downloadsDirectory,
        makeSession: ((Account) -> AccountSession)? = nil
    ) {
        self.registryStore = registryStore
        self.migration = migration
        self.watchedDirectory = watchedDirectory
        let makeSession = makeSession ?? { AccountSession.live($0, defaults: defaults) }
        self.makeSession = makeSession
        // Before the first account reads its plan: what was saved before accounts existed is its own.
        migration?.adoptPreferences(in: defaults)
        let first = makeSession(Account(id: AccountRegistry.firstAccountID, name: Self.defaultName(among: [])))
        sessions = [first]
        selectedID = first.id
        follow(first)
    }

    var selected: AccountSession {
        sessions.first { $0.id == selectedID } ?? sessions[0]
    }

    /// One account needs no name on screen and no way to switch.
    var hasSeveral: Bool {
        sessions.count > 1
    }

    func session(id: String) -> AccountSession? {
        sessions.first { $0.id == id }
    }

    var registry: AccountRegistry {
        AccountRegistry(accounts: sessions.map(\.account), selectedID: selectedID) ?? AccountRegistry(first: selected.name)
    }

    // MARK: - Life cycle

    /// Reads the accounts and starts each one's sync. The first launch with accounts moves the existing caches first:
    /// called before anything may read a cache, so that `whenReady` has something to wait for.
    func start() {
        guard startup == nil else { return }
        startup = Task { [weak self] in await self?.launch() }
    }

    /// Ends once the accounts are known and their caches are where they are read: nothing loads a cache before that.
    func whenReady() async {
        await startup?.value
    }

    private func launch() async {
        if let stored = await registryStore.load() {
            adopt(stored)
        } else {
            await migration?.moveCaches()
            saveRegistry()
        }
        isRunning = true
        for session in sessions {
            run(session)
        }
        applyWindowState()
        for session in sessions {
            await session.buildStore.loadCacheIfNeeded()
            await session.usageStore.start()
        }
        await importer.start()
    }

    private func adopt(_ registry: AccountRegistry) {
        let known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sessions = registry.accounts.map { account in
            guard let session = known[account.id] else {
                let session = makeSession(account)
                follow(session)
                return session
            }
            session.name = account.name
            return session
        }
        selectedID = registry.selectedID
    }

    private func follow(_ session: AccountSession) {
        session.buildStore.onSync = { [weak self, weak session] previous, current in
            guard let self, let session else { return }
            onSync?(session, previous, current)
        }
    }

    private func run(_ session: AccountSession) {
        session.buildStore.start()
        session.settings.mirrorPlan()
        // The Issuer ID is the team in App Store Connect's addresses: the menu's links need it before Settings ever opens.
        Task { await session.settings.load() }
    }

    /// While the Mac sleeps nothing is fetched.
    func suspend() {
        guard isRunning else { return }
        for session in sessions {
            session.buildStore.stop()
        }
        importer.stop()
    }

    func resume() {
        guard isRunning else { return }
        for session in sessions {
            session.buildStore.start()
            Task {
                await session.settings.load()
                await session.usageStore.start()
            }
        }
        Task { await importer.start() }
    }

    func refreshAll() {
        Task { await importer.scan() }
        for session in sessions {
            Task { await session.buildStore.refreshNow() }
        }
    }

    func importUsageExport(at url: URL) async {
        await importer.importFile(at: url)
    }

    // MARK: - What is on screen

    func select(_ id: String) {
        guard id != selectedID, session(id: id) != nil else { return }
        show(id)
    }

    private func show(_ id: String) {
        selectedID = id
        onSelectionChange?()
        applyWindowState()
        saveRegistry()
    }

    /// Every account's cached builds, read once the caches are where they belong.
    func loadCaches() async {
        await whenReady()
        for session in sessions {
            await session.buildStore.loadCacheIfNeeded()
        }
    }

    /// The account that holds a build: an address or a banner names the build alone.
    func owner(ofBuild buildRunID: String) async -> AccountSession? {
        await loadCaches()
        return sessions.first { $0.owns(buildRunID: buildRunID) }
    }

    func windowDidOpen() {
        windowIsOpen = true
        applyWindowState()
    }

    func windowDidClose() {
        windowIsOpen = false
        applyWindowState()
    }

    func screenLockDidChange(isLocked: Bool) {
        for session in sessions {
            session.buildStore.screenLockDidChange(isLocked: isLocked)
        }
    }

    /// Only the account on screen syncs at the window's pace: the others keep the menu's.
    private func applyWindowState() {
        guard isRunning else { return }
        for session in sessions {
            let isShown = windowIsOpen && session.id == selectedID
            if isShown, !session.buildStore.windowIsOpen {
                session.buildStore.windowDidOpen()
            } else if !isShown, session.buildStore.windowIsOpen {
                session.buildStore.windowDidClose()
            }
        }
    }

    // MARK: - Changes

    /// A new account, without a key yet, shown at once so its key can be entered.
    @discardableResult
    func add(name: String? = nil) -> AccountSession {
        let name = name?.nilIfBlank ?? Self.defaultName(among: sessions.map(\.name))
        let session = makeSession(Account(id: UUID().uuidString.lowercased(), name: name))
        follow(session)
        sessions.append(session)
        if isRunning {
            run(session)
            Task { await session.usageStore.start() }
        }
        show(session.id)
        return session
    }

    func rename(_ id: String, to name: String) {
        guard let name = name.nilIfBlank, let session = session(id: id), session.name != name else { return }
        session.name = name
        saveRegistry()
    }

    /// Removes an account with its key, its caches and its billed minutes. The last account stays: its key can be removed instead.
    @discardableResult
    func remove(_ id: String) async -> Bool {
        removalError = nil
        guard hasSeveral, let session = session(id: id) else { return false }
        guard await session.erase() else {
            removalError = session.settings.errorMessage
            return false
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return true }
        sessions.remove(at: index)
        if selectedID == id {
            show(sessions[min(index, sessions.count - 1)].id)
        } else {
            saveRegistry()
        }
        return true
    }

    /// "Account 2", "Account 3"…: the first number no account wears yet.
    static func defaultName(among names: [String]) -> String {
        var number = names.count + 1
        while names.contains(String(localized: "Account \(number)", comment: "Default name of an App Store Connect account in Cumulus; the number tells them apart.")) {
            number += 1
        }
        return String(localized: "Account \(number)", comment: "Default name of an App Store Connect account in Cumulus; the number tells them apart.")
    }

    /// Writes follow one another, so the last change is the one on disk.
    private func saveRegistry() {
        let registry = registry
        let previous = registryWrite
        registryWrite = Task { [registryStore] in
            await previous?.value
            await registryStore.save(registry)
        }
    }

    /// For tests: ends once the registry on disk is the one in memory.
    func registryIsSaved() async {
        await registryWrite?.value
    }
}
