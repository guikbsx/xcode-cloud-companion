import AppKit
import SwiftUI

struct NotificationsSettingsView: View {
    @Bindable var preferences: NotificationPreferences
    let coordinator: NotificationCoordinator
    let accounts: AccountsModel

    var body: some View {
        Form {
            Section {
                permission
            } footer: {
                Text("Notifications follow the app’s own refresh: a build is announced within a minute or so of its end, while Cumulus is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("When a build ends") {
                Toggle(BuildStatus.succeeded.label, isOn: $preferences.builds.succeeded)
                Toggle(isOn: $preferences.builds.failed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BuildStatus.failed.label)
                        Text("With the number of test failures or errors.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(BuildStatus.canceled.label, isOn: $preferences.builds.canceled)
            }
            Section("When a build seems stuck") {
                Toggle(isOn: $preferences.builds.stuck) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A running action takes far longer than usual")
                        Text("Compared with the same action’s usual duration in its workflow. Needs three earlier successful builds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Threshold", selection: $preferences.builds.stuckFactor) {
                    ForEach(BuildNotificationRules.stuckFactors, id: \.self) { factor in
                        Text("\(factor)× the usual duration").tag(factor)
                    }
                }
                .disabled(!preferences.builds.stuck)
            }
            Section {
                Toggle("\(UsageFormat.percent(0.75)) of the plan used", isOn: $preferences.usage.threshold75)
                Toggle("\(UsageFormat.percent(0.9)) of the plan used", isOn: $preferences.usage.threshold90)
                Toggle(isOn: $preferences.usage.pace) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The plan may run out before it resets")
                        Text("Judged from the pace of the cycle, once it is a day old.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("When the plan runs low")
            } footer: {
                Text("Each alert is sent once per cycle. The figure is an estimate until a recent usage export is imported, and the alert says so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if accounts.sessions.isEmpty {
                Section("Apps") {
                    Text("No Xcode Cloud app yet.")
                        .foregroundStyle(.secondary)
                }
            }
            // Every account notifies, whichever one is on screen: each lists its own apps.
            ForEach(accounts.sessions) { session in
                Section(accounts.hasSeveral ? String(localized: "Apps of “\(session.name)”", comment: "Section title: the apps of one App Store Connect account") : String(localized: "Apps")) {
                    let products = session.buildStore.snapshot.products
                    if products.isEmpty {
                        Text("No Xcode Cloud app yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(products) { product in
                        Toggle(product.displayName, isOn: Binding(
                            get: { !preferences.isMuted(product.id) },
                            set: { preferences.setMuted(!$0, productID: product.id) }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await accounts.loadCaches()
            await coordinator.refreshAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await coordinator.refreshAuthorization() }
        }
    }

    @ViewBuilder
    private var permission: some View {
        switch coordinator.authorization {
        case .allowed:
            Label("Notifications are allowed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            LabeledContent {
                Button("Open Notification Settings…") { NSWorkspace.shared.open(Self.notificationSettings) }
            } label: {
                Text("Notifications are turned off for Cumulus in System Settings.")
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            LabeledContent {
                Button("Allow Notifications…") {
                    Task { await coordinator.requestAuthorization() }
                }
            } label: {
                Text("Cumulus asks for your permission the first time it has something to tell you.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let notificationSettings = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
    )!
}
