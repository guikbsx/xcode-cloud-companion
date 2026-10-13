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
    /// How many icons gave their colour since launch: whoever draws the palette reads it, to draw again when it grows.
    private(set) var iconColorReadings = 0
    /// How many times a colour was chosen or given back since launch, read the same way.
    private(set) var colorChoices = 0
    /// Where the apps' repositories are cloned on this Mac, to open a build's files in Xcode.
    let localRepositories: LocalRepositories
    /// Made when the window first shows the account.
    @ObservationIgnored private(set) lazy var windowStores = AccountWindowStores(buildStore: buildStore, extrasStore: extrasStore, paths: paths)
    private let defaults: UserDefaults
    /// Where the icons are read from to find the apps' colours; without one, no icon is read.
    private let iconCache: AppIconCache?
    @ObservationIgnored private var iconReadingAttempts: [String: Date] = [:]

    init(
        account: Account, paths: AccountPaths, settings: SettingsModel, buildStore: BuildStore, usageStore: UsageStore,
        extrasStore: BuildExtrasStore, iconCache: AppIconCache? = nil, defaults: UserDefaults = .standard
    ) {
        id = account.id
        name = account.name
        self.paths = paths
        self.settings = settings
        self.buildStore = buildStore
        self.usageStore = usageStore
        self.extrasStore = extrasStore
        self.defaults = defaults
        self.iconCache = iconCache
        paletteStore = .account(account.id)
        localRepositories = LocalRepositories(accountID: account.id, defaults: defaults)

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
            iconCache: AppIconCache(directory: paths.appIcons),
            defaults: defaults
        )
    }

    var account: Account {
        Account(id: id, name: name)
    }

    /// The apps' colours, brought up to date with the apps that exist.
    func palette(for snapshot: BuildSnapshot, summary: UsageSummary?) -> AppPalette {
        _ = iconColorReadings
        _ = colorChoices
        return paletteStore.refreshed(for: snapshot, summary: summary, defaults: defaults)
    }

    /// Gives an app (by its product name) a colour, or with nil gives it back the colour of its icon.
    func chooseColor(_ choice: AppPalette.Choice?, forApp app: String) {
        var palette = paletteStore.load(from: defaults)
        guard palette.choice(for: app) != choice else { return }
        palette.choose(choice, for: app)
        paletteStore.save(palette, to: defaults)
        colorChoices += 1
    }

    /// Gives each app the colour of its icon. An icon is read once, off the main actor, and again only when it changes;
    /// one that could not be fetched is tried again an hour later at the earliest.
    func readIconColors(in snapshot: BuildSnapshot, now: Date = Date()) async {
        guard let iconCache else { return }
        let known = paletteStore.load(from: defaults)
        for product in snapshot.products {
            guard let appID = product.appID, let icon = snapshot.appIcons[appID] else { continue }
            let fingerprint = AppIconCache.fingerprint(of: icon)
            let lastAttempt = iconReadingAttempts[fingerprint]
            guard known.needsReading(ofIcon: fingerprint, for: product.name),
                  lastAttempt.map({ now.timeIntervalSince($0) >= Self.iconReadingRetryInterval }) ?? true
            else { continue }
            iconReadingAttempts[fingerprint] = now
            guard let data = await iconCache.imageData(appID: appID, icon: icon) else { continue }
            let color = await IconColorReader.color(ofImage: data)
            // Loaded again: the palette may have been saved while the icon was read.
            var palette = paletteStore.load(from: defaults)
            palette.setIconReading(AppPalette.IconReading(icon: fingerprint, color: color), for: product.name)
            paletteStore.save(palette, to: defaults)
            iconColorReadings += 1
        }
    }

    private static let iconReadingRetryInterval: TimeInterval = 3600

    /// The same figure in the menu, the window and the alerts; nil while no reset date is set.
    func usageSummary(now: Date) -> UsageSummary? {
        settings.plan.map { UsageCalculator.summary(snapshot: buildStore.snapshot, ledger: usageStore.ledger, plan: $0, now: now) }
    }

    /// How far the builds are measured, for the menu and the window alike. Without a reset date there is no cycle, but
    /// the builds still get measured: over the last 30 days then.
    func measurement(now: Date, summary: UsageSummary?) -> MeasurementProgress {
        summary?.measurement ?? UsageCalculator.summary(
            snapshot: buildStore.snapshot, ledger: usageStore.ledger,
            plan: UsagePlan(hours: settings.planHours, resetAnchor: now.addingTimeInterval(-30 * 24 * 3600)), now: now
        ).measurement
    }

    /// What the account is fetching right now, or how fresh its builds are.
    func activity(now: Date) -> SyncActivity {
        .current(
            isSyncing: buildStore.isSyncing, activity: buildStore.progress, lastSync: buildStore.snapshot.lastSuccessfulSync,
            errorMessage: buildStore.lastErrorMessage, measurement: measurement(now: now, summary: usageSummary(now: now))
        )
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
