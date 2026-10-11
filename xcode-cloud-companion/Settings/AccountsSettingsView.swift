import SwiftUI

/// The Accounts tab: nothing but a way to add the first account, then the accounts on the left and the one picked on
/// the right, the way Xcode lays out its own.
struct AccountsSettingsView: View {
    let accounts: AccountsModel
    @Bindable var model: AccountsSettingsModel
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
                HStack(spacing: 0) {
                    list
                        .frame(width: 210)
                        .padding([.leading, .vertical], 20)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .confirmationDialog(
            removal.map { String(localized: "Remove the account “\($0.name)” and all its data?") } ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { session in
            Button("Remove Account", role: .destructive) {
                Task { await model.remove(session.id, from: accounts) }
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

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedAccountID }, set: { id in
                if let id { model.selection = .account(id) }
            })) {
                ForEach(accounts.sessions) { session in
                    AccountRow(name: session.name, health: session.health)
                        .tag(session.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                Button { model.startAdding(among: accounts) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .help("Add an Account")
                .accessibilityLabel(Text("Add an Account"))
                Divider().frame(height: 16)
                Button {
                    removal = model.selectedAccountID.flatMap(accounts.session(id:))
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .help("Remove Account…")
                .accessibilityLabel(Text("Remove Account…"))
                .disabled(model.selectedAccountID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .frame(height: 26)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var detail: some View {
        if model.selection == .newAccount, let form = model.newAccount {
            newAccount(form)
        } else if let id = model.selectedAccountID, let session = accounts.session(id: id) {
            AccountDetailView(accounts: accounts, session: session, requestRemoval: { removal = session })
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

/// An account of the list: its name, and what it needs, if anything.
private struct AccountRow: View {
    let name: String
    let health: AccountHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(health.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch health {
        case .connected: .green
        case .keyRefused: .red
        case .missingKey, .missingResetDate: .orange
        }
    }
}
