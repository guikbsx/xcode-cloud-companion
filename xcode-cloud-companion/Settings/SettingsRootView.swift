import SwiftUI

/// The Settings window: a sidebar the way System Settings has one, then the pane it picks. An account is a destination
/// of its own, listed with its state.
struct SettingsRootView: View {
    let accounts: AccountsModel
    @Bindable var navigation: SettingsNavigationModel
    let loginItem: LoginItemModel
    let notificationPreferences: NotificationPreferences
    let notifications: NotificationCoordinator
    let webhook: WebhookService
    let agents: AgentsSettingsModel
    let pro: ProStore
    /// Opens the purchase sheet over this window.
    let openPurchase: () -> Void
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton(visibility: $columnVisibility, hidden: .detailOnly)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { navigation.destination }, set: { select($0) })) {
            Label("General", systemImage: "gearshape").tag(SettingsDestination.general)
            Label("Notifications", systemImage: "bell").tag(SettingsDestination.notifications)
            Label("Agents", systemImage: "terminal").tag(SettingsDestination.agents)
            Label("Cumulus Pro", systemImage: "sparkles").tag(SettingsDestination.pro)
            Section("Accounts") {
                ForEach(accounts.sessions) { session in
                    HStack(spacing: 6) {
                        Label(session.name, systemImage: "cloud")
                        Spacer(minLength: 4)
                        if accounts.isPaused(session) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Paused: following several accounts comes with Cumulus Pro")
                                .accessibilityHidden(true)
                        } else {
                            Circle()
                                .fill(session.health.tint)
                                .frame(width: 8, height: 8)
                                .help(session.health.label)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(accounts.isPaused(session) ? Text("Paused, needs Cumulus Pro") : Text(session.health.label))
                    .tag(SettingsDestination.account(session.id))
                }
                Label("Add an Account…", systemImage: "plus")
                    .foregroundStyle(.tint)
                    .tag(SettingsDestination.newAccount)
            }
        }
    }

    /// One more account comes with Cumulus Pro: the row leads to the purchase sheet instead of the key form.
    private func select(_ destination: SettingsDestination?) {
        if destination == .newAccount, !accounts.canAddAccount {
            openPurchase()
        } else {
            navigation.select(destination, among: accounts)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .general:
            GeneralSettingsView(loginItem: loginItem, accounts: accounts)
                .navigationTitle(Text("General"))
        case .notifications:
            NotificationsSettingsView(preferences: notificationPreferences, coordinator: notifications, webhook: webhook, accounts: accounts, pro: pro)
                .navigationTitle(Text("Notifications"))
        case .agents:
            AgentsSettingsView(model: agents, pro: pro, openPurchase: openPurchase)
                .navigationTitle(Text("Agents"))
        case .pro:
            ProSettingsView(store: pro, openPurchase: openPurchase)
                .navigationTitle(Text("Cumulus Pro"))
        case .accounts:
            AccountsSettingsView(
                accounts: accounts, model: navigation.accountsTab, openPurchase: openPurchase,
                accountWasRemoved: { navigation.accountWasRemoved(from: accounts) }
            )
        }
    }
}

extension AccountHealth {
    /// Green when the key works, red when Apple refuses it, orange while something is missing.
    var tint: Color {
        switch self {
        case .connected: .green
        case .keyRefused: .red
        case .missingKey, .missingResetDate: .orange
        }
    }
}
