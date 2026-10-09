import SwiftUI
import UniformTypeIdentifiers

struct UsageSettingsView: View {
    let usage: UsageStore
    @State private var isImporting = false

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
                HStack {
                    Spacer()
                    Button("Import an Export…") { isImporting = true }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await usage.importFile(at: url) }
            }
        }
    }
}
