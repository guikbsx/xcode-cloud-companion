import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct WatchedFolderTests {
    private func makeFolder(in root: URL, _ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func csv(_ product: String, build: Int = 390) -> Data {
        Data("Build Number,Product,Started At,Usage (Minutes),Workflow\n\(build),\(product),2026-10-10T08:00:00Z,12,CI\n".utf8)
    }

    /// One account with its app already synced, so that exports naming the app have somewhere to go.
    private func oneAccount(_ accounts: TestAccounts) async throws -> (model: AccountsModel, session: AccountSession) {
        let model = accounts.makeModel()
        let session = try await model.add(name: "Work", credentials: TestAccounts.credentials)
        let products = [CIProduct(id: "p-Gamma", name: "Gamma", productType: "APP", appID: nil, appName: nil, bundleID: nil)]
        try await BuildCacheStore(fileURL: session.paths.buildCache).save(BuildSnapshot(products: products, lastSuccessfulSync: CLIFixture.now))
        await model.registryIsSaved()
        return (model, session)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var waited = 0
        while !condition(), waited < 60 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    @Test func nothingIsChosenByDefault() {
        let accounts = TestAccounts()

        #expect(WatchedFolder(defaults: accounts.defaults).url == nil)
        #expect(accounts.model.watchedFolder.url == nil)
    }

    @Test func theChosenFolderIsKeptAndReadBackByANewInstance() throws {
        let accounts = TestAccounts()
        let folder = try makeFolder(in: accounts.root, "Exports")
        let watched = WatchedFolder(defaults: accounts.defaults)

        #expect(watched.choose(folder))
        #expect(watched.url == folder)

        let restarted = WatchedFolder(defaults: accounts.defaults)
        #expect(restarted.url?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())

        restarted.forget()
        #expect(restarted.url == nil)
        #expect(WatchedFolder(defaults: accounts.defaults).url == nil)
    }

    @Test func aFolderThatVanishedIsNoFolderAndIsForgotten() throws {
        let accounts = TestAccounts()
        let folder = try makeFolder(in: accounts.root, "Gone")
        #expect(WatchedFolder(defaults: accounts.defaults).choose(folder))
        try FileManager.default.removeItem(at: folder)

        #expect(WatchedFolder(defaults: accounts.defaults).url == nil)
        #expect(accounts.defaults.data(forKey: WatchedFolder.defaultsKey) == nil)
    }

    @Test func aBookmarkNobodyCanReadIsDropped() {
        let accounts = TestAccounts()
        accounts.defaults.set(Data("not a bookmark".utf8), forKey: WatchedFolder.defaultsKey)

        #expect(WatchedFolder(defaults: accounts.defaults).url == nil)
        #expect(accounts.defaults.data(forKey: WatchedFolder.defaultsKey) == nil)
    }

    @Test func theChangeIsAnnounced() throws {
        let accounts = TestAccounts()
        let folder = try makeFolder(in: accounts.root, "Exports")
        let watched = WatchedFolder(defaults: accounts.defaults)
        var changes = 0
        watched.onChange = { changes += 1 }

        watched.choose(folder)
        watched.forget()
        watched.forget()

        #expect(changes == 2)
    }

    @Test func theSuggestedFolderIsTheRealDownloadsFolder() {
        #expect(WatchedFolder.suggestedFolder?.lastPathComponent == "Downloads")
        #expect(WatchedFolder.suggestedFolder?.path(percentEncoded: false).contains("/Library/Containers/") == false)
    }

    @Test func noFolderMeansNothingIsRead() async throws {
        let accounts = TestAccounts()
        let (model, session) = try await oneAccount(accounts)
        let downloads = try makeFolder(in: accounts.root, "Downloads")
        try csv("Gamma").write(to: downloads.appending(path: "usage_2026-10-10_2026-10-10.csv"))

        model.start()
        await model.whenReady()
        defer { model.suspend() }
        await model.loadCaches()
        model.refreshAll()
        try await Task.sleep(for: .milliseconds(300))

        #expect(session.usageStore.ledger.builds.isEmpty && session.usageStore.ledger.importedFiles.isEmpty)
    }

    @Test func choosingAFolderReadsItAtOnceAndLeavingTheOldOneAlone() async throws {
        let accounts = TestAccounts()
        let (model, session) = try await oneAccount(accounts)
        let first = try makeFolder(in: accounts.root, "First")
        let second = try makeFolder(in: accounts.root, "Second")
        try csv("Gamma", build: 1).write(to: first.appending(path: "usage_2026-10-01_2026-10-01.csv"))
        try csv("Gamma", build: 2).write(to: second.appending(path: "usage_2026-10-02_2026-10-02.csv"))

        model.start()
        await model.whenReady()
        defer { model.suspend() }
        #expect(session.usageStore.ledger.builds.isEmpty)

        model.watchedFolder.choose(first)
        try await waitUntil { session.usageStore.ledger.builds.count == 1 }
        #expect(session.usageStore.ledger.builds.keys.sorted() == ["Gamma#1"])

        model.watchedFolder.choose(second)
        try await waitUntil { session.usageStore.ledger.builds.count == 2 }
        #expect(session.usageStore.ledger.builds.keys.sorted() == ["Gamma#1", "Gamma#2"])

        // The old folder is no longer watched; the new one is.
        try csv("Gamma", build: 3).write(to: first.appending(path: "usage_2026-10-03_2026-10-03.csv"))
        try csv("Gamma", build: 4).write(to: second.appending(path: "usage_2026-10-04_2026-10-04.csv"))
        try await waitUntil { session.usageStore.ledger.builds.keys.contains("Gamma#4") }
        #expect(session.usageStore.ledger.builds.keys.sorted() == ["Gamma#1", "Gamma#2", "Gamma#4"])

        model.watchedFolder.forget()
        try csv("Gamma", build: 5).write(to: second.appending(path: "usage_2026-10-05_2026-10-05.csv"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.usageStore.ledger.builds.keys.sorted() == ["Gamma#1", "Gamma#2", "Gamma#4"])
    }

    @Test func aFolderChosenBeforeTheLaunchIsReadAtTheLaunch() async throws {
        let accounts = TestAccounts()
        let (first, _) = try await oneAccount(accounts)
        let folder = try makeFolder(in: accounts.root, "Exports")
        try csv("Gamma").write(to: folder.appending(path: "usage_2026-10-10_2026-10-10.csv"))
        first.watchedFolder.choose(folder)

        let restarted = accounts.makeModel()
        restarted.start()
        await restarted.whenReady()
        defer { restarted.suspend() }

        #expect(restarted.watchedFolder.url != nil)
        #expect(restarted.sessions.first?.usageStore.ledger.builds.keys.sorted() == ["Gamma#390"])
    }
}
