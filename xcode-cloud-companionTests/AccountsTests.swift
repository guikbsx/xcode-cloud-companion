import AppKit
import SwiftUI
import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AccountRegistryTests {
    @Test func anAccountIsSelectedAsSoonAsThereIsOne() {
        #expect(AccountRegistry(accounts: [], selectedID: nil) == .empty && AccountRegistry.empty.selected == nil)
        #expect(AccountRegistry(accounts: [Account(id: "../x", name: "Bad")], selectedID: "../x") == .empty)

        let registry = AccountRegistry(
            accounts: [Account(id: "a", name: "Personal"), Account(id: "../x", name: "Bad"), Account(id: "a", name: "Twice"), Account(id: "b", name: "Work")],
            selectedID: "gone"
        )
        #expect(registry.accounts.map(\.name) == ["Personal", "Work"])
        #expect(registry.selected?.id == "a")

        var growing = AccountRegistry.empty
        growing.add(Account(id: "w", name: "Work"))
        #expect(growing.selectedID == "w")
    }

    @Test func removingTheSelectedAccountSelectsItsNeighbourAndTheLastOneLeavesNone() throws {
        var registry = AccountRegistry(first: "Personal")
        registry.add(Account(id: "work", name: "Work"))
        registry.add(Account(id: "client", name: "Client"))
        registry.select("work")

        let removedWork = registry.remove("work")
        #expect(removedWork && registry.selectedID == "client")
        let removedClient = registry.remove("client")
        #expect(removedClient && registry.selectedID == AccountRegistry.firstAccountID)
        let removedLast = registry.remove(AccountRegistry.firstAccountID)
        #expect(removedLast && registry == .empty)
        let removedNothing = registry.remove("nobody")
        #expect(!removedNothing)
    }

    @Test func anAccountIsFoundByItsNameWhateverTheCaseOrByItsId() {
        var registry = AccountRegistry(first: "Personal")
        registry.add(Account(id: "work", name: "Café Studio"))
        registry.add(Account(id: "twin", name: "personal"))

        #expect(registry.accounts(matching: " cafe studio ").map(\.id) == ["work"])
        #expect(registry.accounts(matching: "PERSONAL").map(\.id) == [AccountRegistry.firstAccountID, "twin"])
        #expect(registry.accounts(matching: "twin").map(\.name) == ["personal"])
        #expect(registry.accounts(matching: "nobody").isEmpty)
    }

    @Test func theRegistryRoundTripsThroughItsFile() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "accounts-\(UUID().uuidString)/Accounts.json")
        let store = AccountRegistryStore(fileURL: file)
        #expect(await store.load() == nil)

        var registry = AccountRegistry(first: "Personal")
        registry.add(Account(id: "work", name: "Work"))
        registry.select("work")
        await store.save(registry)
        #expect(await store.load() == registry)

        try Data(#"{"accounts":[],"selectedID":"work"}"#.utf8).write(to: file)
        #expect(await store.load() == .empty)
    }

    @Test func twoAccountsShareNoFolder() {
        let root = URL(filePath: "/tmp/root")
        let personal = AccountPaths(accountID: "personal", supportRoot: root, cachesRoot: root.appending(path: "Caches"))
        let work = AccountPaths(accountID: "work", supportRoot: root, cachesRoot: root.appending(path: "Caches"))
        let files: (AccountPaths) -> [URL] = { [$0.buildCache, $0.usageLedger, $0.usagePlan, $0.buildDetails, $0.workflowDetails, $0.appIcons, $0.logs] }

        #expect(Set(files(personal)).isDisjoint(with: files(work)))
        #expect(files(personal).allSatisfy { $0.path().hasPrefix("/tmp/root/Accounts/personal/") || $0.path().hasPrefix("/tmp/root/Caches/Accounts/personal/") })
    }
}

struct AccountDefaultsTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "AccountDefaultsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func whatWasSavedBeforeAccountsExistedGoesToTheFirstAccountOnce() {
        let reset = Date(timeIntervalSince1970: 1_794_059_280)
        defaults.set(100, forKey: "plan.hours")
        defaults.set(reset, forKey: "plan.resetAnchor")
        defaults.set("readOnly", forKey: "keyAccess")
        defaults.set(["run-1"], forKey: "notifications.builds.reportedStuckRunIDs")
        defaults.set(true, forKey: "showsInDock")

        AccountDefaults.adoptLegacyValues(in: defaults)

        #expect(defaults.integer(forKey: "account.default.plan.hours") == 100)
        #expect(defaults.object(forKey: "account.default.plan.resetAnchor") as? Date == reset)
        #expect(defaults.string(forKey: "account.default.keyAccess") == "readOnly")
        #expect(defaults.stringArray(forKey: "account.default.notifications.builds.reportedStuckRunIDs") == ["run-1"])
        #expect(defaults.object(forKey: "plan.hours") == nil && defaults.object(forKey: "keyAccess") == nil)
        // What belongs to the app, not to an account, stays where it is.
        #expect(defaults.bool(forKey: "showsInDock"))

        // A value the account already has is never replaced by an older one.
        defaults.set(25, forKey: "plan.hours")
        AccountDefaults.adoptLegacyValues(in: defaults)
        #expect(defaults.integer(forKey: "account.default.plan.hours") == 100)
    }

    @Test func removingAnAccountsPreferencesLeavesTheOthersAlone() {
        for id in ["personal", "work"] {
            for name in AccountDefaults.names {
                defaults.set("value", forKey: AccountDefaults.key(name, accountID: id))
            }
        }

        AccountDefaults.removeAll(accountID: "work", from: defaults)

        #expect(AccountDefaults.names.allSatisfy { defaults.object(forKey: AccountDefaults.key($0, accountID: "work")) == nil })
        #expect(AccountDefaults.names.allSatisfy { defaults.string(forKey: AccountDefaults.key($0, accountID: "personal")) == "value" })
    }
}

@MainActor
struct AccountsModelTests {
    private let credentials = StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: "pem")
    private let reset = Date(timeIntervalSince1970: 1_794_059_280)

    private func snapshot(products: [String], runID: String? = nil) -> BuildSnapshot {
        BuildSnapshot(
            products: products.map { CIProduct(id: "p-\($0)", name: $0, productType: "APP", appID: nil, appName: nil, bundleID: nil) },
            runs: runID.map { [CLIFixture.run($0, product: "p-\(products[0])", number: 1, created: "2026-10-10T09:00:00Z")] } ?? [],
            lastSuccessfulSync: CLIFixture.now
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func aFreshInstallHasNoAccountAndAMacWithoutKeyGetsNone() async {
        let accounts = TestAccounts()
        let model = accounts.model
        #expect(model.sessions.isEmpty && model.selected == nil && !model.hasSeveral)

        // No registry, no key, no cache: the first launch makes no account of its own.
        let migrated = accounts.makeModel(migration: AccountMigration(
            supportRoot: accounts.root.appending(path: "Support"), cachesRoot: accounts.root.appending(path: "Caches"), paths: accounts.paths(AccountRegistry.firstAccountID)
        ))
        migrated.start()
        await migrated.whenReady()
        await migrated.registryIsSaved()
        #expect(migrated.sessions.isEmpty)
        #expect(await accounts.registryStore.load() == .empty)
    }

    @Test func theFirstAccountIsShownAtOnceButSettingsNeverChangeTheAccountOnScreen() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        var changes = 0
        model.onSelectionChange = { changes += 1 }

        let personal = try await accounts.add("Personal")
        #expect(model.selected === personal && changes == 1)
        #expect(personal.settings.hasStoredKey && accounts.credentials[personal.id]?.current == TestAccounts.credentials)

        let work = try await accounts.add("  ")
        #expect(model.selected === personal && changes == 1 && work.name == "Account 2")
        model.rename(work.id, to: "  Work  ")
        model.rename(work.id, to: "   ")
        await model.registryIsSaved()
        #expect(work.name == "Work" && model.hasSeveral)

        let restarted = accounts.makeModel()
        restarted.start()
        await restarted.whenReady()
        #expect(restarted.sessions.map(\.name) == ["Personal", "Work"])
        #expect(restarted.selectedID == personal.id)
        restarted.suspend()
    }

    @Test func aKeychainThatRefusesTheKeyMakesNoAccount() async {
        let accounts = TestAccounts()
        let refusing = AccountsModel(registryStore: accounts.registryStore, defaults: accounts.defaults, migration: nil) { account in
            AccountSession(
                account: account, paths: accounts.paths(account.id),
                settings: SettingsModel(accountID: account.id, store: RefusingCredentialsStore(saving: false), defaults: accounts.defaults),
                buildStore: BuildStore(credentialsStore: RefusingCredentialsStore(saving: false)),
                usageStore: UsageStore(ledgerStore: UsageLedgerStore(fileURL: accounts.paths(account.id).usageLedger), watchedDirectory: nil),
                extrasStore: BuildExtrasStore(client: { nil }), defaults: accounts.defaults
            )
        }

        await #expect(throws: CredentialsStoreError.self) { try await refusing.add(name: "Work", credentials: TestAccounts.credentials) }
        #expect(refusing.sessions.isEmpty && refusing.selected == nil)
    }

    @Test func newAccountsTakeTheFirstNumberNoAccountWears() {
        #expect(AccountsModel.defaultName(among: []) == "Account 1")
        #expect(AccountsModel.defaultName(among: ["Account 1"]) == "Account 2")
        #expect(AccountsModel.defaultName(among: ["Personal", "Account 3"]) == "Account 4")
        #expect(AccountsModel.defaultName(among: ["Account 2"]) == "Account 3")
    }

    @Test func eachAccountKeepsItsOwnPlanKeyAccessAndColours() async throws {
        let accounts = TestAccounts()
        let personal = try await accounts.add("Personal")
        let work = try await accounts.model.add(name: "Work", credentials: TestAccounts.credentials, keyAccess: .readOnly)

        work.settings.planHours = 100
        work.settings.resetAnchor = reset
        var palette = AppPalette()
        palette.update(ranking: ["Alpha"])
        work.paletteStore.save(palette, to: accounts.defaults)

        #expect(personal.settings.planHours == UsagePlan.defaultHours && personal.settings.resetAnchor == nil)
        #expect(personal.settings.keyAccess == .canLaunch && work.settings.keyAccess == .readOnly)
        #expect(personal.paletteStore.load(from: accounts.defaults) == AppPalette())
        #expect(personal.usageSummary(now: reset) == nil && work.usageSummary(now: reset)?.plan.hours == 100)
        // Read again from the preferences, as after a restart.
        #expect(SettingsModel(accountID: work.id, store: InMemoryCredentialsStore(), defaults: accounts.defaults).planHours == 100)
        #expect(SettingsModel(accountID: personal.id, store: InMemoryCredentialsStore(), defaults: accounts.defaults).planHours == UsagePlan.defaultHours)
    }

    @Test func removingAnAccountErasesItsKeyItsFilesAndItsPreferencesAndNothingOfTheOthers() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        model.select(work.id)
        for session in [personal, work] {
            session.settings.resetAnchor = reset
            try await BuildCacheStore(fileURL: session.paths.buildCache).save(snapshot(products: ["Alpha"]))
            try await UsageLedgerStore(fileURL: session.paths.usageLedger).save(UsageLedger())
            await BuildExtrasCache(directory: session.paths.buildDetails).save(BuildExtras(), runID: "run-1")
            try FileManager.default.createDirectory(at: session.paths.logs, withIntermediateDirectories: true)
        }

        #expect(await model.remove(work.id))
        await model.registryIsSaved()

        #expect(model.sessions.map(\.id) == [personal.id] && model.selected === personal)
        #expect(accounts.credentials[work.id]?.current == nil)
        #expect(!exists(work.paths.support) && !exists(work.paths.caches))
        #expect(accounts.defaults.object(forKey: AccountDefaults.key(AccountDefaults.resetAnchor, accountID: work.id)) == nil)

        #expect(accounts.credentials[personal.id]?.current == TestAccounts.credentials)
        #expect(exists(personal.paths.buildCache) && exists(personal.paths.usageLedger) && exists(personal.paths.logs))
        #expect(await BuildExtrasCache(directory: personal.paths.buildDetails).load(runID: "run-1") != nil)
        #expect(personal.settings.resetAnchor == reset)
        #expect(await accounts.registryStore.load()?.accounts.map(\.id) == [personal.id])
    }

    @Test func theLastAccountGoesTooAndARemovedAccountNeverSyncsAgain() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        let personal = try await accounts.add("Personal")
        var changes = 0
        model.onSelectionChange = { changes += 1 }

        #expect(await model.remove(personal.id))
        await model.registryIsSaved()

        #expect(model.sessions.isEmpty && model.selected == nil && changes == 1)
        #expect(await accounts.registryStore.load() == .empty)
        personal.buildStore.start()
        #expect(await personal.buildStore.synchronize() == .notConfigured)
        #expect(!personal.buildStore.isSyncing)
    }

    @Test func anAccountThatNeverHadAKeyIsForgottenAtLaunchAndTheOthersStay() async throws {
        let accounts = TestAccounts()
        var registry = AccountRegistry.empty
        registry.add(Account(id: AccountRegistry.firstAccountID, name: "Account 1"))
        registry.add(Account(id: "empty", name: "Account 2"))
        registry.add(Account(id: "synced", name: "Synced"))
        await accounts.registryStore.save(registry)
        try await accounts.keychain(AccountRegistry.firstAccountID).save(TestAccounts.credentials)
        // A key lost later, after builds were read, is not a reason to forget the account.
        try await BuildCacheStore(fileURL: accounts.paths("synced").buildCache).save(snapshot(products: ["Alpha"]))
        accounts.defaults.set(100, forKey: AccountDefaults.key(AccountDefaults.planHours, accountID: "empty"))

        let model = accounts.makeModel()
        model.start()
        await model.whenReady()
        await model.registryIsSaved()
        model.suspend()

        #expect(model.sessions.map(\.id) == [AccountRegistry.firstAccountID, "synced"])
        #expect(await accounts.registryStore.load()?.accounts.map(\.id) == [AccountRegistry.firstAccountID, "synced"])
        #expect(accounts.defaults.object(forKey: AccountDefaults.key(AccountDefaults.planHours, accountID: "empty")) == nil)
    }

    @Test func theCachesOfAnInstallFromBeforeAccountsBecomeTheFirstAccounts() async throws {
        let accounts = TestAccounts()
        let support = accounts.root.appending(path: "Support")
        let caches = accounts.root.appending(path: "Caches")
        let old = snapshot(products: ["Alpha"], runID: "run-1")
        try await BuildCacheStore(fileURL: support.appending(path: "BuildCache.json")).save(old)
        await SharedPlanStore(fileURL: support.appending(path: "UsagePlan.json")).save(UsagePlan(hours: 100, resetAnchor: reset))
        await BuildExtrasCache(directory: support.appending(path: "BuildDetails")).save(BuildExtras(issuesComplete: true), runID: "run-1")
        try FileManager.default.createDirectory(at: caches.appending(path: "Logs/action-1"), withIntermediateDirectories: true)
        accounts.defaults.set(100, forKey: "plan.hours")
        accounts.defaults.set(reset, forKey: "plan.resetAnchor")
        try await accounts.keychain(AccountRegistry.firstAccountID).save(TestAccounts.credentials)
        let paths = accounts.paths(AccountRegistry.firstAccountID)

        let model = accounts.makeModel(migration: AccountMigration(supportRoot: support, cachesRoot: caches, paths: paths))
        model.start()
        await model.whenReady()
        await model.registryIsSaved()
        model.suspend()

        // Nothing is asked again: the plan, the builds and what was read of them are the first account's.
        let first = try #require(model.selected)
        #expect(first.id == AccountRegistry.firstAccountID && model.sessions.count == 1)
        #expect(first.settings.plan == UsagePlan(hours: 100, resetAnchor: reset))
        #expect(first.buildStore.snapshot.runs.map(\.id) == ["run-1"])
        #expect(await BuildExtrasCache(directory: paths.buildDetails).load(runID: "run-1")?.issuesComplete == true)
        #expect(exists(paths.logs.appending(path: "action-1")) && exists(paths.usagePlan))
        #expect(!exists(support.appending(path: "BuildCache.json")) && !exists(caches.appending(path: "Logs")))
        #expect(await accounts.registryStore.load()?.accounts.map(\.id) == [AccountRegistry.firstAccountID])
    }

    @Test func aBuildIsFoundInTheAccountThatHoldsIt() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        try await BuildCacheStore(fileURL: personal.paths.buildCache).save(snapshot(products: ["Alpha"], runID: "run-personal"))
        try await BuildCacheStore(fileURL: work.paths.buildCache).save(snapshot(products: ["Beta"], runID: "run-work"))

        #expect(await model.owner(ofBuild: "run-work") === work)
        #expect(await model.owner(ofBuild: "run-personal") === personal)
        #expect(await model.owner(ofBuild: "run-nobody") == nil)
        #expect(personal.owns(buildRunID: "run-personal") && !personal.owns(buildRunID: "run-work"))
    }

    @Test func onlyTheAccountOnScreenIsTheOneTheWindowRefreshes() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        model.select(work.id)
        await model.registryIsSaved()
        model.start()
        await model.whenReady()
        defer { model.suspend() }

        model.windowDidOpen()
        #expect(work.buildStore.windowIsOpen && !personal.buildStore.windowIsOpen)

        model.select(personal.id)
        #expect(personal.buildStore.windowIsOpen && !work.buildStore.windowIsOpen)

        model.windowDidClose()
        #expect(!personal.buildStore.windowIsOpen && !work.buildStore.windowIsOpen)
    }

    @Test func switchingAccountsForgetsTheAppOrBuildOfTheOneBefore() {
        let navigation = NavigationModel()
        navigation.sidebarSelection = .workflow("w-1")
        navigation.selectedBuildID = "run-1"

        navigation.accountDidChange()
        #expect(navigation.sidebarSelection == .allBuilds && navigation.selectedBuildID == nil)

        navigation.sidebarSelection = .overview
        navigation.accountDidChange()
        #expect(navigation.sidebarSelection == .overview)
    }

    @Test func anOverviewAddressMayNameItsAccount() throws {
        let url = try #require(CumulusURL.overview(accountID: "work-1"))

        #expect(url.absoluteString == "cumulus://overview?account=work-1")
        #expect(CumulusURL.destination(of: url) == .overview(accountID: "work-1"))
        #expect(CumulusURL.destination(of: try #require(CumulusURL.overview)) == .overview(accountID: nil))
        #expect(CumulusURL.overview(accountID: "../x") == CumulusURL.overview)
        #expect(CumulusURL.destination(of: try #require(URL(string: "cumulus://overview?account=..%2Fx"))) == .overview(accountID: nil))
    }
}

@MainActor
struct UsageImportRoutingTests {
    private func export(_ products: [String]) -> UsageExport {
        let start = CLIFixture.date("2026-10-01T00:00:00Z")
        return UsageExport(
            builds: products.enumerated().map { BilledBuild(product: $1, buildNumber: $0 + 1, workflow: "CI", startedAt: start, minutes: 10) },
            coverage: DateInterval(start: start, duration: 86_400)
        )
    }

    private func candidate(_ id: String, _ products: Set<String>) -> UsageImportRouting.Candidate {
        UsageImportRouting.Candidate(id: id, productNames: products)
    }

    @Test func anExportGoesToTheAccountWhoseAppsItLists() {
        let candidates = [candidate("personal", ["Alpha", "Beta"]), candidate("work", ["Gamma"])]

        #expect(UsageImportRouting.destination(of: export(["Gamma"]), among: candidates, selectedID: "personal") == .account("work"))
        #expect(UsageImportRouting.destination(of: export(["Alpha", "Beta", "Gamma"]), among: candidates, selectedID: "work") == .account("personal"))
        #expect(UsageImportRouting.destination(of: export(["Delta"]), among: candidates, selectedID: "personal") == .unknown)
    }

    @Test func twoTeamsWithAnAppOfTheSameNameLeaveItToTheAccountOnScreen() {
        let candidates = [candidate("personal", ["Alpha"]), candidate("work", ["Alpha"])]

        #expect(UsageImportRouting.destination(of: export(["Alpha"]), among: candidates, selectedID: "work") == .account("work"))
        #expect(UsageImportRouting.destination(of: export(["Alpha"]), among: candidates, selectedID: "other") == .account("personal"))
    }

    @Test func beforeTheFirstSyncALoneAccountCanOnlyBeTheOne() {
        #expect(UsageImportRouting.destination(of: export(["Alpha"]), among: [candidate("personal", [])], selectedID: "personal") == .account("personal"))
        // Once its apps are known, an export that lists none of them is someone else's.
        #expect(UsageImportRouting.destination(of: export(["Alpha"]), among: [candidate("personal", ["Beta"])], selectedID: "personal") == .unknown)
        #expect(UsageImportRouting.destination(of: export(["Alpha"]), among: [candidate("personal", []), candidate("work", [])], selectedID: "personal") == .unknown)
    }

    private func csv(_ product: String) -> Data {
        Data("Build Number,Product,Started At,Usage (Minutes),Workflow\n390,\(product),2026-10-10T08:00:00Z,12,CI\n".utf8)
    }

    /// Two accounts with their apps already synced, and a Downloads folder of their own.
    private func twoAccounts() async throws -> (model: AccountsModel, personal: AccountSession, work: AccountSession, downloads: URL) {
        let accounts = TestAccounts()
        let downloads = accounts.root.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let model = accounts.makeModel(watchedDirectory: downloads)
        let personal = try await model.add(name: "Personal", credentials: TestAccounts.credentials)
        let work = try await model.add(name: "Work", credentials: TestAccounts.credentials)
        for (session, product) in [(personal, "Alpha"), (work, "Gamma")] {
            let products = [CIProduct(id: "p-\(product)", name: product, productType: "APP", appID: nil, appName: nil, bundleID: nil)]
            try await BuildCacheStore(fileURL: session.paths.buildCache).save(BuildSnapshot(products: products, lastSuccessfulSync: CLIFixture.now))
        }
        model.select(personal.id)
        // The start reads the registry from disk: both accounts have to be in it by then.
        await model.registryIsSaved()
        return (model, personal, work, downloads)
    }

    @Test func exportsWaitingInDownloadsAreReadOnceAndReachTheirOwnAccount() async throws {
        let (model, personal, work, downloads) = try await twoAccounts()
        try csv("Gamma").write(to: downloads.appending(path: "usage_2026-10-10_2026-10-10.csv"))
        try csv("Delta").write(to: downloads.appending(path: "usage_2026-10-09_2026-10-09.csv"))

        model.start()
        await model.whenReady()
        defer { model.suspend() }

        #expect(work.usageStore.ledger.builds.keys.sorted() == ["Gamma#390"])
        // Nobody's apps: it is left for the user to import by hand, and no account is charged with it.
        #expect(personal.usageStore.ledger.builds.isEmpty && personal.usageStore.ledger.importedFiles.isEmpty)
        #expect(work.usageStore.ledger.importedFiles.keys.sorted() == ["usage_2026-10-10_2026-10-10.csv"])
    }

    @Test func anExportPickedByHandForTheWrongAccountGoesToItsOwnAndSaysSo() async throws {
        let (model, personal, work, downloads) = try await twoAccounts()
        await model.loadCaches()
        let file = downloads.appending(path: "export.csv")
        try csv("Gamma").write(to: file)

        await model.importUsageExport(at: file)

        #expect(work.usageStore.ledger.builds.count == 1 && personal.usageStore.ledger.builds.isEmpty)
        #expect(personal.usageStore.lastImportMessage?.contains("“Work”") == true && !personal.usageStore.lastImportFailed)

        // The user insists on an export that lists nobody's apps: it goes to the account on screen.
        try csv("Delta").write(to: file)
        await model.importUsageExport(at: file)
        #expect(personal.usageStore.ledger.builds.keys.sorted() == ["Delta#390"])
    }

    @Test func anExportPickedFromAnAccountsSettingsGoesToThatAccountWhenItsAppsSayNothing() async throws {
        let (model, personal, work, downloads) = try await twoAccounts()
        await model.loadCaches()
        let file = downloads.appending(path: "export.csv")

        try csv("Delta").write(to: file)
        await model.importUsageExport(at: file, from: work)
        #expect(work.usageStore.ledger.builds.keys.sorted() == ["Delta#390"] && personal.usageStore.ledger.builds.isEmpty)

        // Its apps still decide when they name an account.
        try csv("Alpha").write(to: file)
        await model.importUsageExport(at: file, from: work)
        #expect(personal.usageStore.ledger.builds.keys.sorted() == ["Alpha#390"])
        #expect(work.usageStore.lastImportMessage?.contains("“Personal”") == true)
    }
}

@MainActor
struct AccountSwitcherTests {
    private let now = CLIFixture.now

    private func state(accounts: [AccountChoice], needsAPIKey: Bool = false) -> StatusMenuState {
        StatusMenuState(needsAPIKey: needsAPIKey, isSyncing: false, now: now, accounts: accounts, selectedAccountID: accounts.first?.id)
    }

    @Test func theSwitcherOnlyShowsWithSeveralAccounts() {
        let one = [AccountChoice(id: "a", name: "Personal")]
        let two = one + [AccountChoice(id: "b", name: "Work", badge: .failed)]

        #expect(StatusMenuBuilder.accountSwitcher(for: state(accounts: []), actions: StatusMenuActions()) == nil)
        #expect(StatusMenuBuilder.accountSwitcher(for: state(accounts: one), actions: StatusMenuActions()) == nil)
        #expect(StatusMenuBuilder.accountSwitcher(for: state(accounts: two), actions: StatusMenuActions())?.view is AccountSwitcherControl)
        // An account without a key still leads back to the others.
        #expect(StatusMenuBuilder.accountSwitcher(for: state(accounts: two, needsAPIKey: true), actions: StatusMenuActions()) != nil)
    }

    @Test func aClickLandsOnTheAccountDrawnUnderIt() {
        let width: CGFloat = 320
        let inset = AccountSwitcherLayout.inset
        let cell = (width - 2 * inset - 2 * AccountSwitcherLayout.spacing) / 3

        #expect(AccountSwitcherLayout.index(at: inset + 1, width: width, count: 3) == 0)
        #expect(AccountSwitcherLayout.index(at: width / 2, width: width, count: 3) == 1)
        #expect(AccountSwitcherLayout.index(at: width - inset - 1, width: width, count: 3) == 2)
        // The margins and the gap between two accounts belong to nobody.
        #expect(AccountSwitcherLayout.index(at: inset - 1, width: width, count: 3) == nil)
        #expect(AccountSwitcherLayout.index(at: width - inset + 1, width: width, count: 3) == nil)
        #expect(AccountSwitcherLayout.index(at: inset + cell + AccountSwitcherLayout.spacing / 2, width: width, count: 3) == nil)
        #expect(AccountSwitcherLayout.index(at: 10, width: width, count: 0) == nil)

        let frames = AccountSwitcherLayout.frames(width: width, count: 3)
        #expect(frames.map(\.width) == [cell, cell, cell] && frames.first?.minX == inset && frames.last?.maxX == width - inset)
        #expect(AccountSwitcherLayout.frames(width: 10, count: 3).isEmpty)
    }

    @Test func aClickInTheRowSelectsItsAccountAndTheRowThenShowsIt() throws {
        let choices = [AccountChoice(id: "a", name: "Personal"), AccountChoice(id: "b", name: "Work")]
        var selected: [String] = []
        let control = AccountSwitcherControl(accounts: choices, selectedID: "a", select: { selected.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: control.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        control.frame = NSRect(x: 0, y: 0, width: 320, height: control.frame.height)
        window.contentView?.addSubview(control)
        func click(at x: CGFloat) throws {
            control.mouseUp(with: try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: x, y: control.frame.midY), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            )))
        }

        try click(at: 240)
        try click(at: 2)
        try click(at: 80)
        #expect(selected == ["b", "a"])

        // The whole row takes the click, not the drawing inside it.
        #expect(control.hitTest(NSPoint(x: 240, y: control.frame.midY)) === control)
        control.update(accounts: choices + [AccountChoice(id: "c", name: "Client")], selectedID: "b")
        try click(at: 300)
        #expect(selected.last == "c")
    }

    @Test func commandAndADigitSelectAnAccountWhileTheMenuIsOpen() throws {
        let three = [AccountChoice(id: "a", name: "Personal"), AccountChoice(id: "b", name: "Work"), AccountChoice(id: "c", name: "Client")]
        var selected: [String] = []
        let items = StatusMenuBuilder.accountShortcuts(for: state(accounts: three), select: { selected.append($0) })

        #expect(items.map(\.keyEquivalent) == ["1", "2", "3"] && items.map(\.title) == ["Personal", "Work", "Client"])
        #expect(items.allSatisfy { $0.keyEquivalentModifierMask == .command })
        // They take no room in the menu: the switcher is what shows the accounts.
        #expect(items.allSatisfy { $0.isHidden && $0.allowsKeyEquivalentWhenHidden })
        #expect(items.map(\.state) == [.on, .off, .off])

        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        func press(_ digit: String) throws -> Bool {
            menu.performKeyEquivalent(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: 0
            )))
        }
        let second = try press("2"), fourth = try press("4")
        #expect(second && !fourth && selected == ["b"])
    }

    @Test func oneAccountHasNoShortcutAndNineAccountsAtMostHaveOne() {
        let one = [AccountChoice(id: "a", name: "Personal")]
        let twelve = (1...12).map { AccountChoice(id: "id-\($0)", name: "Account \($0)") }

        #expect(StatusMenuBuilder.accountShortcuts(for: state(accounts: one), select: { _ in }).isEmpty)
        #expect(StatusMenuBuilder.accountShortcuts(for: state(accounts: []), select: { _ in }).isEmpty)
        #expect(StatusMenuBuilder.accountShortcuts(for: state(accounts: twelve), select: { _ in }).map(\.keyEquivalent) == (1...9).map(String.init))
    }

    @Test func voiceOverMeetsOneRadioButtonPerAccountAndCanPressIt() async throws {
        let choices = [AccountChoice(id: "a", name: "Personal", badge: .succeeded), AccountChoice(id: "b", name: "Work", badge: .failed)]
        var selected: [String] = []
        let control = AccountSwitcherControl(accounts: choices, selectedID: "a", select: { selected.append($0) })
        control.frame = NSRect(x: 0, y: 0, width: 320, height: control.frame.height)
        let elements = { (control.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement } }

        #expect(control.accessibilityRole() == .radioGroup && control.accessibilityLabel() == "Account")
        #expect(elements().count == 2 && elements().allSatisfy { $0.accessibilityRole() == .radioButton })
        #expect(elements().map { $0.accessibilityValue() as? NSNumber } == [1, 0])
        // The account that is not on screen says how its builds go; the menu already says it for the other.
        #expect(elements().map { $0.accessibilityLabel() ?? "" } == ["Personal", "Work, Failed"])
        #expect(elements().map { $0.accessibilityHelp() ?? "" } == ["Shortcut: ⌘1", "Shortcut: ⌘2"])
        #expect(elements().map { $0.accessibilityFrameInParentSpace() } == AccountSwitcherLayout.frames(width: 320, count: 2))
        // The drawing says nothing of its own: VoiceOver would read every account twice.
        #expect(!(control.accessibilityChildren() ?? []).contains { $0 is NSHostingView<AccountSwitcherView> })
        #expect(control.toolTip == "Switch accounts with ⌘1 to ⌘2")

        #expect(elements()[1].accessibilityPerformPress())
        for _ in 0..<50 where selected.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selected == ["b"])

        control.update(accounts: choices, selectedID: "b")
        #expect(elements().map { $0.accessibilityValue() as? NSNumber } == [0, 1])
        #expect(elements().map { $0.accessibilityLabel() ?? "" } == ["Personal, Succeeded", "Work"])

        control.update(accounts: [choices[0]], selectedID: "a")
        #expect(elements().count == 1 && control.toolTip == nil)
    }

    @Test func theMenuShowsTheSelectedAccountAndNamesThemAll() async throws {
        let accounts = TestAccounts()
        let model = accounts.model
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        model.select(work.id)
        let failed = BuildSnapshot(
            products: CLIFixture.products,
            runs: [CLIFixture.run("run-1", product: "p-alpha", number: 1, created: "2026-10-10T09:00:00Z", status: .failed)],
            lastSuccessfulSync: now
        )
        try await BuildCacheStore(fileURL: work.paths.buildCache).save(failed)
        await model.loadCaches()

        let shown = StatusItemController.state(of: model, palette: AppPalette(), now: now)
        #expect(shown.selectedAccountID == work.id && shown.snapshot.runs.map(\.id) == ["run-1"])
        #expect(shown.accounts == [AccountChoice(id: personal.id, name: "Personal"), AccountChoice(id: work.id, name: "Work", badge: .failed)])

        model.select(personal.id)
        let other = StatusItemController.state(of: model, palette: AppPalette(), now: now)
        #expect(other.selectedAccountID == personal.id && other.snapshot.runs.isEmpty)
        #expect(other.accounts.map(\.badge) == [nil, .failed])
    }

    @Test func withoutAnAccountTheMenuOnlyLeadsToAddingOne() {
        var added = false
        let state = StatusItemController.state(of: TestAccounts().model, palette: AppPalette(), now: now)
        let items = StatusMenuBuilder.items(for: state, actions: StatusMenuActions(addAccount: { added = true }))

        #expect(!state.hasAccounts && state.needsAPIKey)
        #expect(StatusMenuBuilder.accountSwitcher(for: state, actions: StatusMenuActions()) == nil)
        #expect(items.map(\.title) == ["Add an Account…", "", "Quit Cumulus"])
        (items.first?.target as? MenuActionTarget)?.run(items.first)
        #expect(added)
    }

    @Test func theDotOfTheBarSpeaksForEveryAccount() {
        let run: (CIExecutionProgress, CICompletionStatus?) -> BuildSnapshot = { progress, status in
            BuildSnapshot(runs: [CLIFixture.run("run", product: "p", number: 1, created: "2026-10-10T09:00:00Z", progress: progress, status: status)])
        }
        let succeeded = run(.complete, .succeeded), failed = run(.complete, .failed), running = run(.running, nil), canceled = run(.complete, .canceled)

        #expect(MenuBarBadge.status(for: [BuildSnapshot]()) == nil)
        #expect(MenuBarBadge.status(for: [.empty, succeeded]) == .succeeded)
        // A failure in one account does not hide behind another account's success, nor a build under way behind a failure.
        #expect(MenuBarBadge.status(for: [succeeded, failed]) == .failed)
        #expect(MenuBarBadge.status(for: [failed, running, succeeded]) == .running)
        #expect(MenuBarBadge.status(for: [canceled, succeeded]) == .succeeded)
        #expect(MenuBarBadge.status(for: [canceled, .empty]) == .stopped)
    }
}
