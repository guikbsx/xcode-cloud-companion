import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var loginItem: LoginItemModel
    @AppStorage(ActivationPolicyCoordinator.showsInDockKey) private var showsInDock = true

    var body: some View {
        Form {
            Section("Startup") {
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
            }
            Section("Window") {
                Toggle(isOn: $showsInDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in the Dock")
                        Text("While the Cumulus window is open. Takes effect the next time it opens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
}
