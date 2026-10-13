import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct ProAccountsTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    /// Three accounts added while Pro was open, as someone who then let the subscription end.
    private func threeAccounts(_ accounts: TestAccounts, source: StubProSource) async throws -> (ProStore, [AccountSession]) {
        await source.set([.verified(ProTransaction(product: .lifetime, purchaseDate: now))])
        let store = ProStore(source: source)
        await store.refresh()
        accounts.model.pro = store
        var sessions: [AccountSession] = []
        for name in ["Personal", "Work", "Client"] {
            sessions.append(try await accounts.add(name))
        }
        return (store, sessions)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func aFirstAccountIsFreeAndOneMoreComesWithPro() async throws {
        let accounts = TestAccounts()
        accounts.model.pro = ProStore(source: StubProSource(), forced: .free)
        #expect(accounts.model.canAddAccount, "the first account needs nothing")

        try await accounts.add("Personal")
        #expect(!accounts.model.canAddAccount)

        let tab = AccountsSettingsModel()
        tab.startAdding(among: accounts.model)
        #expect(tab.newAccount == nil && tab.selection != .newAccount, "no key form opens without Pro")

        accounts.model.pro = ProStore(source: StubProSource(), forced: .lifetime(since: now))
        #expect(accounts.model.canAddAccount)
        tab.startAdding(among: accounts.model)
        #expect(tab.selection == .newAccount)
    }

    @Test func whenProEndsEveryAccountButTheFirstIsPausedAndNothingIsErased() async throws {
        let accounts = TestAccounts()
        let source = StubProSource()
        let (store, sessions) = try await threeAccounts(accounts, source: source)
        accounts.model.select(sessions[2].id)
        #expect(accounts.model.selectedID == sessions[2].id && accounts.model.activeSessions.count == 3)

        await source.set([])
        await store.refresh()
        await settle()

        #expect(accounts.model.sessions.map(\.name) == ["Personal", "Work", "Client"], "every account is still listed")
        #expect(accounts.model.activeSessions.map(\.name) == ["Personal"])
        #expect(sessions.map { accounts.model.isPaused($0) } == [false, true, true])
        #expect(accounts.model.selectedID == sessions[0].id, "a paused account cannot stay on screen")
        for session in sessions {
            await session.settings.load()
            #expect(session.settings.hasStoredKey, "\(session.name) keeps its key")
        }
    }

    @Test func aPausedAccountLeadsToThePurchaseSheetInsteadOfBeingShown() async throws {
        let accounts = TestAccounts()
        let source = StubProSource()
        let (store, sessions) = try await threeAccounts(accounts, source: source)
        await source.set([])
        await store.refresh()
        await settle()
        var asked = 0
        accounts.model.onPausedSelection = { asked += 1 }

        accounts.model.select(sessions[1].id)

        #expect(asked == 1 && accounts.model.selectedID == sessions[0].id)
    }

    @Test func onlyTheFirstAccountSyncsWithoutProAndAllOfThemAgainWhenProIsBack() async throws {
        let accounts = TestAccounts()
        let source = StubProSource()
        for name in ["Personal", "Work", "Client"] {
            try await accounts.add(name)
        }
        await accounts.model.registryIsSaved()
        let model = accounts.makeModel()
        let store = ProStore(source: source)
        model.pro = store
        model.start()
        await model.whenReady()
        await settle()
        // Cumulus Pro is not known yet: the accounts after the first wait rather than sync on a guess.
        #expect(model.sessions.map(\.buildStore.hasAttemptedSync) == [true, false, false])
        #expect(model.sessions.map { model.isPaused($0) } == [false, false, false], "nothing is called paused before Pro is known")

        await store.refresh()
        await settle()
        #expect(model.sessions.map { model.isPaused($0) } == [false, true, true])
        model.refreshAll()
        await settle()
        #expect(model.sessions.map(\.buildStore.hasAttemptedSync) == [true, false, false], "a paused account asks Apple nothing, a refresh included")

        await source.set([.verified(ProTransaction(product: .lifetime, purchaseDate: now))])
        await store.refresh()
        await settle()
        try? await Task.sleep(for: .milliseconds(300))
        model.suspend()
        #expect(model.activeSessions.count == 3)
        #expect(model.sessions.map(\.buildStore.hasAttemptedSync) == [true, true, true], "with Pro back, every account syncs again")
    }

    @Test func removingAPausedAccountWorksAndRemovingTheFirstFollowsTheNext() async throws {
        let accounts = TestAccounts()
        let source = StubProSource()
        let (store, sessions) = try await threeAccounts(accounts, source: source)
        await source.set([])
        await store.refresh()
        await settle()

        #expect(await accounts.model.remove(sessions[2].id))
        #expect(accounts.model.sessions.map(\.name) == ["Personal", "Work"])

        #expect(await accounts.model.remove(sessions[0].id))
        #expect(accounts.model.sessions.map(\.name) == ["Work"])
        #expect(!accounts.model.isPaused(sessions[1]) && accounts.model.selectedID == sessions[1].id)
    }

    @Test func theMenuMarksAPausedAccountAndTheBadgeIgnoresIt() async throws {
        let accounts = TestAccounts()
        let source = StubProSource()
        let (store, sessions) = try await threeAccounts(accounts, source: source)
        await source.set([])
        await store.refresh()
        await settle()

        let choices = AccountChoice.all(of: accounts.model)

        #expect(choices.map(\.isPaused) == [false, true, true])
        #expect(choices.dropFirst().allSatisfy { $0.badge == nil })
        _ = sessions
    }
}

struct ProPausedCommandTests {
    @Test func withoutProStatusAnswersForTheFirstAccountOnly() async throws {
        let environment = try await CLIFixture.environmentWithTwoAccounts()
        ProStatusStore(directory: environment.directory).save(ProStatus(isActive: false, writtenAt: CLIFixture.now))

        let first = await CumulusCLI.run(arguments: ["status", "--json"], environment: environment)
        #expect(first.exitCode == 0)
        let named = await CumulusCLI.run(arguments: ["status", "--account", CLIFixture.account.name, "--json"], environment: environment)
        #expect(named.exitCode == 0, "naming the first account is the same as naming none")

        let paused = await CumulusCLI.run(arguments: ["status", "--account", "Work", "--json"], environment: environment)
        #expect(paused.exitCode == 9 && paused.stdout.isEmpty)
        #expect(paused.stderr.contains("PRO_REQUIRED") && paused.stderr.contains("is paused"))
    }

    @Test func withProEveryAccountAnswers() async throws {
        let environment = try await CLIFixture.environmentWithTwoAccounts()

        let work = await CumulusCLI.run(arguments: ["status", "--account", "Work", "--json"], environment: environment)

        #expect(work.exitCode == 0)
        #expect(try CLIFixture.json(work).meta["account"] as? String == "Work")
    }
}
