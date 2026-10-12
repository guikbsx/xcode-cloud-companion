import Foundation
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct SettingsNavigationTests {
    private func navigation(_ accounts: TestAccounts) -> SettingsNavigationModel {
        SettingsNavigationModel(defaults: accounts.defaults)
    }

    @Test func withoutAnAccountTheWindowOpensOnTheWayToAddOne() {
        let accounts = TestAccounts()
        let navigation = navigation(accounts)

        navigation.open(for: accounts.model, addingAccount: false)

        #expect(navigation.pane == .accounts)
        #expect(navigation.destination == nil, "no account to light in the sidebar: the pane says how to add the first")
    }

    @Test func thePaneIsRememberedByNameUnderTheKeyTheTabsUsed() {
        let accounts = TestAccounts()
        accounts.defaults.set("notifications", forKey: SettingsNavigationModel.storedKey)

        let navigation = navigation(accounts)
        #expect(navigation.pane == .notifications && navigation.destination == .notifications, "what a version with tabs stored is understood")

        navigation.select(.agents, among: accounts.model)
        #expect(accounts.defaults.string(forKey: SettingsNavigationModel.storedKey) == "agents")
        #expect(self.navigation(accounts).pane == .agents)

        accounts.defaults.set("usage", forKey: SettingsNavigationModel.storedKey)
        #expect(self.navigation(accounts).pane == .general, "a tab that no longer exists leads to General")
    }

    @Test func anAccountIsADestinationAndPickingItNeverChangesTheOneOnScreen() async throws {
        let accounts = TestAccounts()
        let first = try await accounts.model.add(name: "First", credentials: TestAccounts.credentials)
        let second = try await accounts.model.add(name: "Second", credentials: TestAccounts.credentials)
        let shown = accounts.model.selectedID
        let navigation = navigation(accounts)

        navigation.select(.account(second.id), among: accounts.model)

        #expect(navigation.pane == .accounts && navigation.destination == .account(second.id))
        #expect(accounts.model.selectedID == shown, "the menu and the main window keep their account")

        navigation.select(.newAccount, among: accounts.model)
        #expect(navigation.destination == .newAccount && navigation.accountsTab.newAccount != nil)

        navigation.select(.general, among: accounts.model)
        #expect(navigation.destination == .general)
        _ = first
    }

    @Test func theWindowOpensOnTheAccountThatLacksSomethingAndOnANewAccountWhenAsked() async throws {
        let accounts = TestAccounts()
        // No reset date yet: the account needs attention.
        let session = try await accounts.model.add(name: "Team", credentials: TestAccounts.credentials)
        accounts.defaults.set("agents", forKey: SettingsNavigationModel.storedKey)
        let navigation = navigation(accounts)

        navigation.open(for: accounts.model, addingAccount: false)
        #expect(session.health.needsAttention)
        #expect(navigation.destination == .account(session.id))

        navigation.open(for: accounts.model, addingAccount: true)
        #expect(navigation.destination == .newAccount)
    }

    @Test func removingTheLastAccountLeadsToGeneralAndRemovingAnotherSelectsItsNeighbour() async throws {
        let accounts = TestAccounts()
        let first = try await accounts.model.add(name: "First", credentials: TestAccounts.credentials)
        let second = try await accounts.model.add(name: "Second", credentials: TestAccounts.credentials)
        let navigation = navigation(accounts)
        navigation.select(.account(second.id), among: accounts.model)

        await navigation.accountsTab.remove(second.id, from: accounts.model)
        navigation.accountWasRemoved(from: accounts.model)
        #expect(navigation.destination == .account(first.id))

        await navigation.accountsTab.remove(first.id, from: accounts.model)
        navigation.accountWasRemoved(from: accounts.model)
        #expect(accounts.model.sessions.isEmpty && navigation.pane == .general)
    }

    @Test func theSidebarButtonHidesTheSidebarAndBringsItBackFromAnyStateWithoutIt() {
        // Three columns: the sidebar goes, the builds and the sheet stay. Two columns: the pane stays alone.
        #expect(SidebarToggleButton.next(after: .all, hidden: .doubleColumn) == .doubleColumn)
        #expect(SidebarToggleButton.next(after: .doubleColumn, hidden: .doubleColumn) == .all)
        #expect(SidebarToggleButton.next(after: .all, hidden: .detailOnly) == .detailOnly)
        // Hidden by the menu command or by a drag: the button still brings it back.
        #expect(SidebarToggleButton.next(after: .detailOnly, hidden: .doubleColumn) == .all)
        #expect(SidebarToggleButton.next(after: .detailOnly, hidden: .detailOnly) == .all)
        // `.automatic` compares equal to `.doubleColumn`: the windows start from `.all`, and a first click from it shows everything.
        #expect(NavigationSplitViewVisibility.automatic == .doubleColumn)
        #expect(SidebarToggleButton.next(after: .automatic, hidden: .doubleColumn) == .all)
    }
}
