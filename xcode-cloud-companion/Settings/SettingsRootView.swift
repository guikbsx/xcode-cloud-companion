import SwiftUI

/// The Settings window: a sidebar the way System Settings has one, then the pane it picks. An account is a destination
/// of its own, listed with its state.
struct SettingsRootView: View {
    let accounts: AccountsModel
    @Bindable var navigation: SettingsNavigationModel
    let loginItem: LoginItemModel
    let notificationPreferences: NotificationPreferences
    let notifications: NotificationCoordinator
    let agents: AgentsSettingsModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { navigation.destination }, set: { navigation.select($0, among: accounts) })) {
            Label("General", systemImage: "gearshape").tag(SettingsDestination.general)
            Label("Notifications", systemImage: "bell").tag(SettingsDestination.notifications)
            Label("Agents", systemImage: "terminal").tag(SettingsDestination.agents)
            Section("Accounts") {
                ForEach(accounts.sessions) { session in
                    HStack(spacing: 6) {
                        Label(session.name, systemImage: "cloud")
                        Spacer(minLength: 4)
                        Circle()
                            .fill(session.health.tint)
                            .frame(width: 8, height: 8)
                            .help(session.health.label)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(session.health.label))
                    .tag(SettingsDestination.account(session.id))
                }
                Label("Add an Account…", systemImage: "plus")
                    .foregroundStyle(.tint)
                    .tag(SettingsDestination.newAccount)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .general:
            GeneralSettingsView(loginItem: loginItem, accounts: accounts)
                .navigationTitle(Text("General"))
        case .notifications:
            NotificationsSettingsView(preferences: notificationPreferences, coordinator: notifications, accounts: accounts)
                .navigationTitle(Text("Notifications"))
        case .agents:
            AgentsSettingsView(model: agents)
                .navigationTitle(Text("Agents"))
        case .accounts:
            AccountsSettingsView(accounts: accounts, model: navigation.accountsTab, accountWasRemoved: { navigation.accountWasRemoved(from: accounts) })
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
