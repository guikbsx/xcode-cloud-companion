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
/// one the menu, the window and the `cumulus` command show. There is none until a key is added.
@Observable
final class AccountsModel {
    private(set) var sessions: [AccountSession] = []
    private(set) var selectedID: String?
    /// Why the last removal did not happen (the keychain refused), for Settings to show.
    private(set) var removalError: String?
    /// Called after each successful sync of an account, with its snapshot before and after.
    @ObservationIgnored var onSync: ((_ session: AccountSession, _ previous: BuildSnapshot, _ current: BuildSnapshot) -> Void)?
    /// Called after each read of an app's TestFlight builds, for the banners.
    @ObservationIgnored var onTestFlightRead: ((_ session: AccountSession, _ app: TestFlightApp, _ builds: [TestFlightBuild]) -> Void)?
    /// Called as soon as another account is on screen: what was selected in the window belonged to the one before.
    @ObservationIgnored var onSelectionChange: (() -> Void)?

    private let registryStore: AccountRegistryStore
    private let migration: AccountMigration?
    private let makeSession: (Account) -> AccountSession
    /// Cumulus Pro, handed to every account; set before the accounts start. Nil leaves every function open.
    @ObservationIgnored var pro: ProStore? {
        didSet { watchPro() }
    }
    /// Called when a paused account is asked for: the way to Cumulus Pro.
    @ObservationIgnored var onPausedSelection: (() -> Void)?
    /// The accounts whose sync is held back for want of Cumulus Pro.
    @ObservationIgnored private var heldIDs: Set<String> = []
    @ObservationIgnored private lazy var importer = UsageImporter(
        sessions: { [weak self] in self?.sessions ?? [] },
        selected: { [weak self] in self?.selected },
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
        self.makeSession = makeSession ?? { AccountSession.live($0, defaults: defaults) }
        // Before the first account reads its plan: what was saved before accounts existed is its own.
        migration?.adoptPreferences(in: defaults)
    }

    private func newSession(_ account: Account) -> AccountSession {
        let session = makeSession(account)
        session.pro = pro
        return session
    }

    // MARK: - Cumulus Pro

    /// Without Cumulus Pro only the first account is followed. The others are paused: they stay listed, with their key,
    /// their cache and their settings, and neither sync nor ask Apple anything until Pro is back.
    func isPaused(_ session: AccountSession) -> Bool {
        guard let pro, pro.hasResolved, !pro.allows(.multipleAccounts) else { return false }
        return session.id != sessions.first?.id
    }

    var activeSessions: [AccountSession] {
        sessions.filter { !isPaused($0) }
    }

    /// A first account is free; one more comes with Cumulus Pro.
    var canAddAccount: Bool {
        sessions.isEmpty || (pro?.allows(.multipleAccounts) ?? true)
    }

    /// Until Cumulus Pro is known, the accounts after the first wait: none of them asks Apple anything on the strength
    /// of a guess. What is selected is left alone meanwhile, so a Pro user finds the account they left.
    private func mayFollow(_ session: AccountSession) -> Bool {
        guard let pro, session.id != sessions.first?.id else { return true }
        return pro.hasResolved && pro.allows(.multipleAccounts)
    }

    private func watchPro() {
        guard let pro else { return }
        withObservationTracking {
            _ = pro.isPro
            _ = pro.hasResolved
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyProState()
                self?.watchPro()
            }
        }
    }

    /// Holds back the accounts Cumulus Pro no longer covers and lets go of those it covers again; a paused account
    /// cannot stay on screen.
    func applyProState() {
        if let selected, isPaused(selected), let first = sessions.first {
            show(first.id)
        }
        guard isRunning else { return }
        for session in sessions {
            let follows = mayFollow(session)
            if !follows, !heldIDs.contains(session.id) {
                heldIDs.insert(session.id)
                session.buildStore.stop()
            } else if follows, heldIDs.contains(session.id) {
                heldIDs.remove(session.id)
                session.buildStore.start()
            }
        }
        heldIDs.formIntersection(sessions.map(\.id))
        applyWindowState()
    }

    var selected: AccountSession? {
        sessions.first { $0.id == selectedID }
    }

    /// One account needs no name on screen and no way to switch.
    var hasSeveral: Bool {
        sessions.count > 1
    }

    func session(id: String) -> AccountSession? {
        sessions.first { $0.id == id }
    }

    var registry: AccountRegistry {
        AccountRegistry(accounts: sessions.map(\.account), selectedID: selectedID)
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
            await forgetAccountsThatNeverHadAKey()
        } else {
            if let migration {
                await migration.moveCaches()
                await adoptInstallationFromBeforeAccounts()
            }
            saveRegistry()
        }
        isRunning = true
        for session in sessions {
            run(session)
        }
        applyProState()
        for session in sessions {
            await session.buildStore.loadCacheIfNeeded()
            await session.usageStore.start()
        }
        await importer.start()
    }

    /// Accounts added before the start are already running in memory: they are kept as they are.
    private func adopt(_ registry: AccountRegistry) {
        let known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sessions = registry.accounts.map { account in
            if let session = known[account.id] {
                session.name = account.name
                return session
            }
            let session = newSession(account)
            follow(session)
            return session
        }
        selectedID = registry.selectedID
    }

    /// The first account of an installation from before accounts existed: its key is in the keychain under the first id,
    /// and its caches were just moved into its folders. A Mac that never had a key starts with no account.
    private func adoptInstallationFromBeforeAccounts() async {
        let session = newSession(Account(id: AccountRegistry.firstAccountID, name: Self.defaultName(among: [])))
        await session.settings.load()
        guard session.settings.hasStoredKey || FileManager.default.fileExists(atPath: session.paths.buildCache.path(percentEncoded: false)) else { return }
        follow(session)
        sessions = [session]
        selectedID = session.id
    }

    /// An account added without a key, as the first version with accounts did, has nothing to show: it goes. One whose
    /// keychain could not be read stays, since nothing says its key is gone.
    private func forgetAccountsThatNeverHadAKey() async {
        var kept: [AccountSession] = []
        for session in sessions {
            await session.settings.load()
            let neverSynced = !FileManager.default.fileExists(atPath: session.paths.buildCache.path(percentEncoded: false))
            if !session.settings.hasStoredKey, session.settings.errorMessage == nil, neverSynced, await session.erase() {
                continue
            }
            kept.append(session)
        }
        guard kept.count != sessions.count else { return }
        sessions = kept
        if selected == nil {
            selectedID = sessions.first?.id
        }
        saveRegistry()
    }

    private func follow(_ session: AccountSession) {
        session.buildStore.onSync = { [weak self, weak session] previous, current in
            guard let self, let session else { return }
            Task { await session.readIconColors(in: current) }
            Task { await session.testFlight.sync(snapshot: current) }
            onSync?(session, previous, current)
        }
        session.testFlight.onRead = { [weak self, weak session] app, builds in
            guard let self, let session else { return }
            onTestFlightRead?(session, app, builds)
        }
    }

    private func run(_ session: AccountSession) {
        if mayFollow(session) {
            session.buildStore.start()
        } else {
            heldIDs.insert(session.id)
        }
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
            if mayFollow(session) {
                session.buildStore.start()
            }
            Task {
                await session.settings.load()
                await session.usageStore.start()
            }
        }
        Task { await importer.start() }
    }

    func refreshAll() {
        Task { await importer.scan() }
        for session in sessions where mayFollow(session) {
            Task { await session.buildStore.refreshNow() }
        }
    }

    /// `account` is the one the export was picked from, when it was not the account on screen.
    func importUsageExport(at url: URL, from account: AccountSession? = nil) async {
        await importer.importFile(at: url, shown: account)
    }

    // MARK: - What is on screen

    func select(_ id: String) {
        guard id != selectedID, let session = session(id: id) else { return }
        guard !isPaused(session) else {
            onPausedSelection?()
            return
        }
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
        for session in sessions where mayFollow(session) {
            session.buildStore.screenLockDidChange(isLocked: isLocked)
        }
    }

    /// Opening the window refreshes the account it shows, when its last sync is not fresh; the pace itself is the same for all.
    private func applyWindowState() {
        guard isRunning else { return }
        for session in sessions {
            let isShown = windowIsOpen && session.id == selectedID && mayFollow(session)
            if isShown, !session.buildStore.windowIsOpen {
                session.buildStore.windowDidOpen()
            } else if !isShown, session.buildStore.windowIsOpen {
                session.buildStore.windowDidClose()
            }
        }
    }

    // MARK: - Changes

    /// A new account, once Apple accepted its key: nothing exists before. Its key goes into the keychain under the
    /// account's id. It is shown at once only when it is the first account: Settings never changes what the menu shows.
    @discardableResult
    func add(
        name: String, credentials: StoredCredentials, keyAccess: KeyAccess = .defaultValue, productNames: [String] = []
    ) async throws(CredentialsStoreError) -> AccountSession {
        let session = newSession(Account(id: UUID().uuidString.lowercased(), name: name.nilIfBlank ?? Self.defaultName(among: sessions.map(\.name))))
        try await session.settings.adopt(credentials, productNames: productNames)
        session.settings.keyAccess = keyAccess
        follow(session)
        sessions.append(session)
        if isRunning {
            run(session)
            Task { await session.usageStore.start() }
        }
        if selectedID == nil {
            show(session.id)
        } else {
            saveRegistry()
        }
        return session
    }

    func rename(_ id: String, to name: String) {
        guard let name = name.nilIfBlank, let session = session(id: id), session.name != name else { return }
        session.name = name
        saveRegistry()
    }

    /// Removes an account with its key, its caches and its billed minutes; after the last one, the app has no account.
    @discardableResult
    func remove(_ id: String) async -> Bool {
        removalError = nil
        guard let session = session(id: id) else { return false }
        guard await session.erase() else {
            removalError = session.settings.errorMessage ?? session.webhook.errorMessage
            return false
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return true }
        sessions.remove(at: index)
        if selectedID == id {
            if sessions.isEmpty {
                selectedID = nil
                onSelectionChange?()
                saveRegistry()
            } else {
                show(sessions[min(index, sessions.count - 1)].id)
            }
        } else {
            saveRegistry()
        }
        // Without Pro, the account that is now the first is followed again.
        applyProState()
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
