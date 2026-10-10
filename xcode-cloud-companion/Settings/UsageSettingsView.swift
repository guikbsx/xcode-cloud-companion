import SwiftUI
import UniformTypeIdentifiers

struct UsageSettingsView: View {
    let accounts: AccountsModel
    @State private var isImporting = false

    /// The billed minutes of the account on screen.
    private var usage: UsageStore { accounts.selected.usageStore }

    var body: some View {
        Form {
            Section("Billed Minutes") {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Without an export, the usage shown is an **estimate** computed from the builds' durations. The plan and its reset date are set in the Configuration tab.")
                        Text("For Apple's exact figures: in **Xcode Cloud › Usage**, click **Export as CSV**. The app picks the file up from Downloads on its own.")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
            Section {
                if accounts.hasSeveral {
                    LabeledContent("Account", value: accounts.selected.name)
                }
                if let lastImport = usage.ledger.lastImport {
                    LabeledContent("Last Export Imported", value: lastImport.formatted(date: .abbreviated, time: .shortened))
                    if let coverage = usage.ledger.lastCoverage {
                        LabeledContent("Covers", value: (coverage.start..<max(coverage.start, coverage.end.addingTimeInterval(-1))).formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledContent("Builds with Billed Minutes", value: usage.ledger.builds.count.formatted())
                } else {
                    Label("No usage export imported yet.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if let message = usage.lastImportMessage {
                    Label(message, systemImage: usage.lastImportFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(usage.lastImportFailed ? .red : .green)
                }
            } footer: {
                VStack(alignment: .trailing, spacing: 6) {
                    if accounts.hasSeveral {
                        Text("An export goes to the account whose apps it lists, whichever account is shown here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Import an Export…") { isImporting = true }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await accounts.importUsageExport(at: url) }
            }
        }
    }
}
