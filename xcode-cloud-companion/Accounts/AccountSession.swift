import Foundation
import Observation

/// One account at work: its key and plan, its builds and its billed minutes, synced with its own key and its own request budget.
@Observable
final class AccountSession: Identifiable {
    let id: String
    var name: String
    let paths: AccountPaths
    let settings: SettingsModel
    let buildStore: BuildStore
    let usageStore: UsageStore
    /// A build's issues, tests and artifacts: the window and the `cumulus` command load them through the same store.
    let extrasStore: BuildExtrasStore
    let paletteStore: AppPaletteStore
    /// Made when the window first shows the account.
    @ObservationIgnored private(set) lazy var windowStores = AccountWindowStores(buildStore: buildStore, extrasStore: extrasStore, paths: paths)
    private let defaults: UserDefaults

    init(
        account: Account, paths: AccountPaths, settings: SettingsModel, buildStore: BuildStore, usageStore: UsageStore,
        extrasStore: BuildExtrasStore, defaults: UserDefaults = .standard
    ) {
        id = account.id
        name = account.name
        self.paths = paths
        self.settings = settings
        self.buildStore = buildStore
        self.usageStore = usageStore
        self.extrasStore = extrasStore
        self.defaults = defaults
        paletteStore = .account(account.id)

        settings.onCredentialsChange = { [buildStore] in
            Task { await buildStore.credentialsDidChange() }
        }
        settings.onReset = { [paths, usageStore] in
            await BuildExtrasCache(directory: paths.buildDetails).deleteAll()
            await WorkflowDetailsCache(directory: paths.workflowDetails).deleteAll()
            await AppIconCache(directory: paths.appIcons).deleteAll()
            await LogCache(directory: paths.logs).deleteAll()
            await usageStore.reset()
        }
    }

    /// The account as the app runs it: key in the keychain under its id, caches in its own folders.
    static func live(_ account: Account, defaults: UserDefaults = .standard) -> AccountSession {
        let paths = AccountPaths(accountID: account.id)
        let credentials = KeychainCredentialsStore(account: account.id)
        let buildStore = BuildStore(credentialsStore: credentials, cacheStore: BuildCacheStore(fileURL: paths.buildCache))
        return AccountSession(
            account: account, paths: paths,
            settings: SettingsModel(accountID: account.id, store: credentials, defaults: defaults, planMirror: SharedPlanStore(fileURL: paths.usagePlan)),
            buildStore: buildStore,
            // Exports are read once for every account, then handed to the one they belong to: no account watches Downloads itself.
            usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: paths.usageLedger), watchedDirectory: nil),
            extrasStore: BuildExtrasStore(cache: BuildExtrasCache(directory: paths.buildDetails), client: { [buildStore] in await buildStore.detailClient() }),
            defaults: defaults
        )
    }

    var account: Account {
        Account(id: id, name: name)
    }

    /// The same figure in the menu, the window and the alerts; nil while no reset date is set.
    func usageSummary(now: Date) -> UsageSummary? {
        settings.plan.map { UsageCalculator.summary(snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: now) }
    }

    func owns(buildRunID: String) -> Bool {
        buildStore.snapshot.runs.contains { $0.id == buildRunID }
    }

    /// Forgets the account: its key, then everything read or entered with it. If the keychain refuses, nothing else is
    /// touched and the account stays.
    func erase() async -> Bool {
        guard await settings.removeKey() else { return false }
        await buildStore.retire()
        usageStore.stop()
        await paths.deleteAll()
        AccountDefaults.removeAll(accountID: id, from: defaults)
        return true
    }
}
