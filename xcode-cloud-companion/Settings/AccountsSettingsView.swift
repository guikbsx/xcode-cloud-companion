import SwiftUI

/// The pane of an account: its settings, a new account's form, or the way to add the first one. The accounts themselves
/// are rows of the Settings sidebar.
struct AccountsSettingsView: View {
    let accounts: AccountsModel
    @Bindable var model: AccountsSettingsModel
    /// Opens the purchase sheet over the Settings window.
    var openPurchase: () -> Void = {}
    /// Told once an account is gone, so the window can leave the pane after the last one.
    var accountWasRemoved: () -> Void = {}
    @State private var removal: AccountSession?

    var body: some View {
        Group {
            if accounts.sessions.isEmpty {
                if let form = model.newAccount, model.selection == .newAccount {
                    newAccount(form)
                } else {
                    noAccount
                }
            } else {
                detail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            removal.map { String(localized: "Remove the account “\($0.name)” and all its data?") } ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { session in
            Button("Remove Account", role: .destructive) {
                Task {
                    await model.remove(session.id, from: accounts)
                    accountWasRemoved()
                }
            }
        } message: { _ in
            Text("Its key leaves the keychain, and its cached builds, imported usage exports, plan and reset date are deleted. The other accounts are not touched.")
        }
    }

    private var noAccount: some View {
        ContentUnavailableView {
            Label("Follow your first team", systemImage: "person.2")
        } description: {
            Text("Cumulus reads your Xcode Cloud builds with an App Store Connect API key.")
        } actions: {
            Button("Add an Account") { model.startAdding(among: accounts) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selection == .newAccount, let form = model.newAccount {
            newAccount(form)
                .navigationTitle(Text("New Account"))
        } else if let id = model.selectedAccountID, let session = accounts.session(id: id) {
            AccountDetailView(accounts: accounts, session: session, openPurchase: openPurchase, requestRemoval: { removal = session })
                // What was typed belongs to the account it was typed for.
                .id(session.id)
        } else {
            ContentUnavailableView("Select an account", systemImage: "person.2")
        }
    }

    private func newAccount(_ form: NewAccountModel) -> some View {
        NewAccountView(
            form: form,
            save: { Task { await model.saveNewAccount(into: accounts) } },
            cancel: { model.cancelAdding(among: accounts) }
        )
    }
}
