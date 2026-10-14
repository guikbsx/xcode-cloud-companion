import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var loginItem: LoginItemModel
    /// The accounts, for how fresh the builds of the one on screen are; nil shows the app's name and version alone.
    var accounts: AccountsModel?
    @AppStorage(ActivationPolicyCoordinator.showsInDockKey) private var showsInDock = true
    @AppStorage(FailureInsightFeature.settingKey) private var summarizesFailures = true
    @AppStorage(BuildETAFeature.settingKey) private var showsTimeLeft = true

    var body: some View {
        // The app's own line goes across the pane, above the columns when there are two.
        SettingsColumns(header: { identity }) {
            Section("Startup and Window") {
                Toggle(isOn: $loginItem.opensAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                        Text("The app starts with your session and stays in the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if loginItem.requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    } label: {
                        Text("Waiting for your approval in System Settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage = loginItem.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Toggle(isOn: $showsInDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in the Dock")
                        Text("While the Cumulus window is open. Takes effect the next time it opens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Menu Bar") {
                Toggle(isOn: $showsTimeLeft) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the time left in the menu bar")
                        Text("From the median duration of the last 30 builds of the same workflow. It is an estimate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } trailing: {
            Section("Failed Builds") {
                let model = FailureInsightFeature.ModelStatus.current
                Toggle(isOn: $summarizesFailures) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Summarize failed builds with Apple Intelligence")
                        Text(model.reason ?? String(localized: "Runs on this Mac: nothing about your builds leaves it. The summary may be wrong.", comment: "Caption of the Apple Intelligence setting in Settings"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model != .available)
            }
            Section("Language") {
                LabeledContent {
                    Button("Language & Region…") { NSWorkspace.shared.open(Self.languageSettings) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follows the language of macOS")
                        Text("English or French. To pick another language for this app only, use System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    /// What the app is and whether it is up to date: its icon, its version, and how fresh the builds on screen are.
    private var identity: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Cumulus")
                    .font(.title2.weight(.bold))
                // "Updated 2 minutes ago" is only true for a minute: the tick redraws the line.
                TickingView(interval: 60) { now in
                    Text(UsageFormat.dotted([Self.versionText(), freshness(now: now)].compactMap(\.self)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Nothing without an account, or before its first sync.
    private func freshness(now: Date) -> String? {
        guard let lastSync = accounts?.selected?.buildStore.snapshot.lastSuccessfulSync else { return nil }
        return SyncActivityView.updatedText(lastSync: lastSync, now: now)
    }

    /// “Version 1.2 (45)”, read from the bundle; nil when the bundle says nothing.
    nonisolated static func versionText(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let version = (info?["CFBundleShortVersionString"] as? String)?.nilIfBlank else { return nil }
        guard let build = (info?["CFBundleVersion"] as? String)?.nilIfBlank else {
            return String(localized: "Version \(version)", comment: "The app's version, in Settings")
        }
        return String(localized: "Version \(version) (\(build))", comment: "The app's version and build number, in Settings")
    }

    private static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
}
