import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var loginItem: LoginItemModel
    let usage: UsageStore
    @State private var isImportingKey = false
    @State private var isImportingUsage = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            apiKeySection
            planSection
            usageSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .fileImporter(isPresented: $isImportingKey, allowedContentTypes: [Self.privateKeyType]) { result in
            if case .success(let url) = result {
                model.importPrivateKey(from: url)
            }
        }
        .confirmationDialog("Remove the API key from the keychain?", isPresented: $isConfirmingRemoval) {
            Button("Remove Key", role: .destructive) {
                Task { await model.removeKey() }
            }
        } message: {
            Text("The app will stop reading Xcode Cloud data until a key is imported again.")
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            TextField("Issuer ID", text: $model.issuerID, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                .disabled(model.hasStoredKey)
            TextField("Key ID", text: $model.keyID, prompt: Text("ABCDE12345"))
                .disabled(model.hasStoredKey)
            LabeledContent("Private Key") {
                privateKeyStatus
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            connectionStatus
        } header: {
            Text("App Store Connect API")
        } footer: {
            HStack {
                Text("Create a key in App Store Connect › Users and Access › Integrations. The key is kept in your keychain.")
                    .foregroundStyle(.secondary)
                Spacer()
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var privateKeyStatus: some View {
        switch model.keyState {
        case .none:
            Button("Import .p8 File…") { isImportingKey = true }
        case .imported(let fileName):
            HStack {
                Label(fileName, systemImage: "doc.badge.checkmark")
                Button("Change…") { isImportingKey = true }
            }
        case .stored:
            Label("Stored in Keychain", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connectionState {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Contacting App Store Connect…")
            }
        case .connected(let productNames):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    productNames.count == 1
                        ? String(localized: "Connected — 1 Xcode Cloud app found")
                        : String(localized: "Connected — \(productNames.count) Xcode Cloud apps found"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                if !productNames.isEmpty {
                    Text(productNames.formatted(.list(type: .and)))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if model.hasStoredKey {
            Button("Remove Key…", role: .destructive) { isConfirmingRemoval = true }
            Button("Test Connection") {
                Task { await model.testConnection() }
            }
            .disabled(model.connectionState == .testing)
        } else {
            Button("Save and Test") {
                Task { await model.saveAndTestConnection() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
    }

    // MARK: - Plan

    private var planSection: some View {
        Section {
            Picker("Plan", selection: $model.planHours) {
                ForEach(UsagePlan.availableHours, id: \.self) { hours in
                    Text(Duration.seconds(hours * 3600).formatted(.units(allowed: [.hours], width: .wide)))
                        .tag(hours)
                }
            }
            DatePicker("Next Reset", selection: $model.nextReset, displayedComponents: [.date, .hourAndMinute])
            if model.resetAnchor == nil {
                Label("Not set yet: copy the reset date shown in App Store Connect.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Xcode Cloud Plan")
        } footer: {
            HStack {
                Text("App Store Connect › Xcode Cloud › Usage shows the plan and its reset date.")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Open Usage", destination: AppStoreConnectLinks.xcodeCloudUsage)
            }
        }
    }

    // MARK: - Usage exports

    private var usageSection: some View {
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
        } header: {
            Text("Billed Minutes")
        } footer: {
            HStack {
                Text("In App Store Connect › Xcode Cloud › Usage, click “Export as CSV”: the file is picked up from Downloads automatically.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import…") { isImportingUsage = true }
            }
        }
        .fileImporter(isPresented: $isImportingUsage, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await usage.importFile(at: url) }
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Open at Login", isOn: $loginItem.opensAtLogin)
            if loginItem.requiresApproval {
                HStack {
                    Label("Waiting for your approval in System Settings.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…") { loginItem.openSystemSettings() }
                }
            }
            if let errorMessage = loginItem.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private static let privateKeyType = UTType(filenameExtension: "p8") ?? .data
}
