#if DEBUG
import AppKit
import SwiftUI

/// Debug-only window used to compare the estimate with App Store Connect (XCO-6).
final class UsageDiagnosticWindowController {
    private let accounts: AccountsModel
    private var window: NSWindow?

    init(accounts: AccountsModel) {
        self.accounts = accounts
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = UsageDiagnosticView(accounts: accounts)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Usage Diagnostic"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        return window
    }
}

private struct UsageDiagnosticView: View {
    let accounts: AccountsModel

    private var buildStore: BuildStore { accounts.selected.buildStore }
    private var settings: SettingsModel { accounts.selected.settings }

    private var report: String {
        UsageDiagnostic.report(
            snapshot: buildStore.snapshot,
            plan: settings.plan,
            syncState: .init(isConfigured: buildStore.isConfigured, isSyncing: buildStore.isSyncing, progress: buildStore.progress, lastError: buildStore.lastError, rateLimit: buildStore.rateLimit),
            now: Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(.background)
            HStack {
                if buildStore.isSyncing {
                    ProgressView().controlSize(.small)
                    Text(buildStore.progress ?? "")
                        .foregroundStyle(.secondary)
                }
                if let message = buildStore.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("Copy Report" as String) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("Sync Now" as String) {
                    Task { await buildStore.refreshNow() }
                }
                .disabled(buildStore.isSyncing)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
#endif
