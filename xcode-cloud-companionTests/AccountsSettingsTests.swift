import CryptoKit
import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct AccountsSettingsTests {
    private let reset = Date(timeIntervalSince1970: 1_794_059_280)
    private let pem = P256.Signing.PrivateKey().pemRepresentation

    private func keyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)/AuthKey_ABCDE12345.p8")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(pem.utf8).write(to: url)
        return url
    }

    /// Apple as the form's connection test meets it: products for a good key, a 401 otherwise.
    private func settingsModel(accepting: Bool) -> AccountsSettingsModel {
        let transport = MockTransport { _ in
            accepting ? MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data()) : MockTransport.Reply(status: 401)
        }
        return AccountsSettingsModel(makeClient: { AppStoreConnectClient(credentials: $0, transport: transport) })
    }

    @Test func anAccountIsOnlyMadeOnceAppleAcceptedItsKey() async throws {
        let accounts = TestAccounts()
        let tab = settingsModel(accepting: false)
        tab.prepare(for: accounts.model, addingAccount: true)
        let form = try #require(tab.newAccount)
        #expect(tab.selection == .newAccount && form.name == "Account 1" && !form.canSave)

        form.importPrivateKey(from: try keyFile())
        form.issuerID = "  69a6de70-03db-47e3-e053-5b8c7c11a4d1 "
        #expect(form.keyID == "ABCDE12345" && form.keyFileName == "AuthKey_ABCDE12345.p8" && form.canSave)

        await tab.saveNewAccount(into: accounts.model)
        #expect(accounts.model.sessions.isEmpty && accounts.credentials.values.allSatisfy { $0.current == nil })
        #expect(form.refusal != nil && tab.selection == .newAccount)

        let accepted = settingsModel(accepting: true)
        accepted.prepare(for: accounts.model, addingAccount: true)
        let second = try #require(accepted.newAccount)
        second.name = "Studio Nimbus"
        second.importPrivateKey(from: try keyFile())
        second.issuerID = "69a6de70-03db-47e3-e053-5b8c7c11a4d1"
        second.keyAccess = .readOnly
        await accepted.saveNewAccount(into: accounts.model)

        let session = try #require(accounts.model.sessions.first)
        #expect(session.name == "Studio Nimbus" && session.settings.keyAccess == .readOnly)
        #expect(accounts.credentials[session.id]?.current?.issuerID == "69a6de70-03db-47e3-e053-5b8c7c11a4d1")
        #expect(accepted.selection == .account(session.id) && accepted.newAccount == nil)
        if case .connected(let names) = session.settings.connectionState {
            #expect(!names.isEmpty)
        } else {
            Issue.record("the new account does not show the apps the test found")
        }
    }

    @Test func aFormThatIsCancelledLeavesNothingAndGoesBackWhereItWas() async throws {
        let accounts = TestAccounts()
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        let tab = settingsModel(accepting: true)
        tab.selection = .account(work.id)

        tab.startAdding(among: accounts.model)
        tab.newAccount?.name = "Typed"
        tab.cancelAdding(among: accounts.model)
        #expect(tab.selection == .account(work.id) && tab.newAccount == nil)
        #expect(accounts.model.sessions.map(\.id) == [personal.id, work.id])

        // A new form starts afresh.
        tab.startAdding(among: accounts.model)
        #expect(tab.newAccount?.name == "Account 3")
    }

    @Test func pickingAnAccountInSettingsLeavesTheMenusAccountAlone() async throws {
        let accounts = TestAccounts()
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        personal.settings.resetAnchor = reset
        work.settings.resetAnchor = reset
        let tab = settingsModel(accepting: true)

        tab.prepare(for: accounts.model, addingAccount: false)
        #expect(tab.selection == .account(personal.id))
        tab.selection = .account(work.id)

        #expect(accounts.model.selectedID == personal.id)
        // Opened again, Settings come back to what was picked there.
        tab.prepare(for: accounts.model, addingAccount: false)
        #expect(tab.selection == .account(work.id))
    }

    @Test func settingsOpenOnTheAccountThatNeedsSomething() async throws {
        let accounts = TestAccounts()
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        personal.settings.resetAnchor = reset
        let tab = settingsModel(accepting: true)
        tab.selection = .account(personal.id)

        tab.prepare(for: accounts.model, addingAccount: false)
        #expect(tab.selection == .account(work.id))
        #expect(work.health == .missingResetDate && personal.health == .connected)
    }

    @Test func removingTheAccountShownInSettingsShowsTheNextOneThenNothing() async throws {
        let accounts = TestAccounts()
        let personal = try await accounts.add("Personal")
        let work = try await accounts.add("Work")
        let tab = settingsModel(accepting: true)
        tab.selection = .account(personal.id)

        await tab.remove(personal.id, from: accounts.model)
        #expect(tab.selection == .account(work.id))
        await tab.remove(work.id, from: accounts.model)
        #expect(tab.selection == nil && accounts.model.sessions.isEmpty)

        tab.prepare(for: accounts.model, addingAccount: false)
        #expect(tab.selection == nil)
    }

    @Test func anAccountsLineSaysWhatToFixFirst() {
        #expect(AccountHealth.of(hasKey: false, lastError: .unauthorized(status: 401), hasResetDate: false) == .missingKey)
        #expect(AccountHealth.of(hasKey: true, lastError: .unauthorized(status: 401), hasResetDate: false) == .keyRefused)
        #expect(AccountHealth.of(hasKey: true, lastError: .rateLimited, hasResetDate: false) == .missingResetDate)
        #expect(AccountHealth.of(hasKey: true, lastError: .network(.notConnectedToInternet), hasResetDate: true) == .connected)
        #expect(!AccountHealth.connected.needsAttention && AccountHealth.keyRefused.needsAttention)
    }
}
