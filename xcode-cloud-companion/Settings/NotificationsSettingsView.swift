import AppKit
import SwiftUI

struct NotificationsSettingsView: View {
    @Bindable var preferences: NotificationPreferences
    let coordinator: NotificationCoordinator
    let webhook: WebhookService
    let accounts: AccountsModel

    var body: some View {
        SettingsColumns {
            permission
            Section("When a build ends") {
                Toggle(isOn: $preferences.builds.succeeded) {
                    state(.succeeded)
                }
                Toggle(isOn: $preferences.builds.failed) {
                    state(.failed, detail: "With the number of test failures or errors.")
                }
                Toggle(isOn: $preferences.builds.canceled) {
                    state(.canceled)
                }
            }
            Section {
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
                        Text(verbatim: "\(factor)×")
                            .accessibilityLabel(Text("\(factor)× the usual duration"))
                            .tag(factor)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.builds.stuck)
            } header: {
                Text("When a build seems stuck")
            }
            Section {
                Toggle(isOn: $preferences.builds.slowdown) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A workflow’s successful builds got slower")
                        Text("Judged on the last 30 successful builds: at least 15 % and a minute longer, over five builds or more. Said once for each slowdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("When a workflow slows down")
            }
            Section {
                Toggle(isOn: $preferences.builds.testFlightAvailable) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A build is available to external testers")
                        Text("Said once, when TestFlight puts a build in testing with an external group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $preferences.builds.testFlightExpiry) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The build external testers are on expires within a week")
                        Text("Said once, unless a newer build has reached them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("TestFlight")
            } footer: {
                Text("Cumulus asks App Store Connect about an app’s latest builds at most every 15 minutes while one is processing or waiting for its beta review, and once a day otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            Section("When an agent acts") {
                Toggle(isOn: $preferences.builds.agentLaunches) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A build was started by `cumulus run` or an MCP tool")
                        Text("Agents may start three builds an hour per account; each one uses compute hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $preferences.builds.agentTestFlight) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A TestFlight build was given to groups or expired by an agent")
                        Text("Agents may make ten such changes an hour per account; an expiration can’t be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            ForEach(accounts.sessions) { session in
                WebhookSettingsSection(
                    session: session, service: webhook, showsName: accounts.hasSeveral
                )
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
                    let snapshot = session.buildStore.snapshot
                    let palette = session.paletteStore.load()
                    if snapshot.products.isEmpty {
                        Text("No Xcode Cloud app yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.products) { product in
                        Toggle(isOn: Binding(
                            get: { !preferences.isMuted(product.id) },
                            set: { preferences.setMuted(!$0, productID: product.id) }
                        )) {
                            HStack(spacing: 8) {
                                AppIconView(
                                    name: product.displayName, swatch: palette.swatch(for: product.name), size: 20,
                                    artwork: session.windowStores.icons.artwork(of: product, in: snapshot)
                                )
                                Text(product.displayName)
                            }
                        }
                    }
                }
            }
        }
        .task {
            await accounts.loadCaches()
            await coordinator.refreshAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await coordinator.refreshAuthorization() }
        }
    }

    /// A state of a build as the build list draws it: its glyph in its colour, then its name.
    private func state(_ status: BuildStatus, detail: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: 8) {
            StatusBadge(status: status, size: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Whether macOS lets the banners through, as a band at the head of the pane: green when it does, with the way to
    /// change it otherwise. Nothing is asked for here on its own.
    @ViewBuilder
    private var permission: some View {
        let delay = Text("Notifications follow the app’s own refresh: a build is announced within a minute or so of its end, while Cumulus is running.")
            .font(.caption)
            .foregroundStyle(.secondary)
        switch coordinator.authorization {
        case .allowed:
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications are allowed.").fontWeight(.semibold)
                        delay
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .listRowBackground(Color.green.opacity(0.12))
            }
        case .denied:
            Section {
                LabeledContent {
                    Button("Open Notification Settings…") { NSWorkspace.shared.open(Self.notificationSettings) }
                } label: {
                    Label {
                        Text("Notifications are turned off for Cumulus in System Settings.")
                    } icon: {
                        Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color.orange.opacity(0.12))
            } footer: {
                delay.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .notDetermined:
            Section {
                LabeledContent {
                    Button("Allow Notifications…") {
                        Task { await coordinator.requestAuthorization() }
                    }
                } label: {
                    Label {
                        Text("Cumulus asks for your permission the first time it has something to tell you.")
                    } icon: {
                        Image(systemName: "bell.badge").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                delay.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static let notificationSettings = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
    )!
}
