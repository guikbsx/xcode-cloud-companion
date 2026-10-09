import SwiftUI
import UniformTypeIdentifiers

/// The API key and the plan: the two things the app needs before it shows anything.
struct ConfigurationSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var isImportingKey = false
    @State private var isConfirmingRemoval = false
    @State private var isDropTargeted = false
    @State private var showsGuides = false

    private var showsKeyGuide: Bool { !model.hasStoredKey || showsGuides }

    var body: some View {
        Form {
            if model.hasStoredKey {
                connectedHeader
            } else {
                keyIntro
            }
            if showsKeyGuide {
                keyGuide
            }
            if model.hasStoredKey {
                storedKey
                foundApps
            } else {
                keyInput
            }
            planIntro
            if showsKeyGuide {
                planGuide
            }
            planInput
            if model.hasStoredKey {
                Section {
                    Button(showsGuides ? "Hide the guides" : "Where to find the key and the reset date?") {
                        showsGuides.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
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

    // MARK: - Key, before it is set

    private var keyIntro: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Store Connect API Key")
                        .font(.headline)
                    Text("The app reads your Xcode Cloud builds with an API key. It changes nothing on your account, and the key stays in your keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var keyGuide: some View {
        Section {
            GuideStep(number: 1) {
                Text("In App Store Connect, open **Users and Access › Integrations › App Store Connect API**, **Team Keys** tab.")
                Link("Open in App Store Connect ↗", destination: AppStoreConnectLinks.integrations)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            GuideStep(number: 2) {
                Text("Click **+**, name the key “Cumulus” and give it **Developer** access.")
            }
            GuideStep(number: 3) {
                Text("Copy the **Issuer ID**, shown above the table of keys, then the **Key ID** on the new key's row.")
                APIKeySchema()
                Text("Diagram of the App Store Connect page: the two values to copy are highlighted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GuideStep(number: 4) {
                Text("Click **Download** to get the `AuthKey_ABCDE12345.p8` file. **Apple offers it only once**: keep it somewhere safe, or import it right away below.")
            }
        } header: {
            Text("Create the key in 4 steps")
        } footer: {
            Text("Only the Account Holder or an Admin of the team can create a team key.")
        }
    }

    // MARK: - Key input

    private var keyInput: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                if case .imported(let fileName) = model.keyState {
                    Label(fileName, systemImage: "doc.badge.checkmark")
                } else {
                    Text("Drop the `.p8` file here")
                }
                Button("Choose a File…") { isImportingKey = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(isDropTargeted ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "p8" }) else { return false }
                model.importPrivateKey(from: url)
                return true
            } isTargeted: { isDropTargeted = $0 }
            TextField("Key ID", text: $model.keyID, prompt: Text(verbatim: "ABCDE12345"))
            Text("Filled in on its own from the name of the `AuthKey_…p8` file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Issuer ID", text: $model.issuerID, prompt: Text(verbatim: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            connectionStatus
        } header: {
            Text("Enter the key")
        } footer: {
            HStack {
                Spacer()
                Button("Save and Test") {
                    Task { await model.saveAndTestConnection() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connectionState {
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Contacting App Store Connect…")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 3) {
                Label("App Store Connect refuses this key.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                Text("The Issuer ID or the Key ID may not match the file, or the key was revoked. Check step 3.")
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle, .connected:
            EmptyView()
        }
    }

    // MARK: - Key, once set

    private var connectedHeader: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    switch model.connectionState {
                    case .connected(let names):
                        Text("Connected to App Store Connect")
                            .font(.headline)
                        Text("\(names.count) Xcode Cloud apps found", comment: "Number of Xcode Cloud apps the key gives access to")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .testing:
                        Text("Contacting App Store Connect…")
                            .font(.headline)
                    case .failed(let message):
                        Text("App Store Connect refuses this key.")
                            .font(.headline)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .idle:
                        Text("API key saved")
                            .font(.headline)
                        Text("Run the connection test to check it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                switch model.connectionState {
                case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .testing: ProgressView().controlSize(.small)
                case .idle: Image(systemName: "key.fill").foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var storedKey: some View {
        Section {
            LabeledContent("Private Key") {
                Label("In the keychain", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Key ID", value: model.keyID)
            LabeledContent("Issuer ID", value: Self.masked(model.issuerID))
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
        } footer: {
            HStack {
                Button("Remove Key…", role: .destructive) { isConfirmingRemoval = true }
                Spacer()
                Button("Test Connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.connectionState == .testing)
            }
        }
    }

    @ViewBuilder
    private var foundApps: some View {
        if case .connected(let names) = model.connectionState {
            Section {
                Text(names.isEmpty ? String(localized: "No Xcode Cloud app yet.") : names.formatted(.list(type: .and)))
            } header: {
                Text("Xcode Cloud Apps")
            } footer: {
                Text("An app is missing? It has no Xcode Cloud workflow yet, or the key has no access to this team.")
            }
        }
    }

    // MARK: - Plan

    private var planIntro: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xcode Cloud Plan")
                        .font(.headline)
                    Text("Apple does not expose the plan or its reset date in the API. Without the right date, the gauge counts the hours over the wrong cycle.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var planGuide: some View {
        Section("Where to find them") {
            GuideStep(number: 1) {
                Text("In App Store Connect, open **Xcode Cloud › Usage**.")
                Link("Open Usage ↗", destination: AppStoreConnectLinks.xcodeCloudUsage)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            GuideStep(number: 2) {
                Text("At the top of the page, note the plan's **number of hours** and the **reset date**.")
                UsageSchema()
                Text("Diagram of the App Store Connect page: the two values to copy are highlighted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var planInput: some View {
        Section {
            Picker("Compute hours per month", selection: $model.planHours) {
                ForEach(UsagePlan.availableHours, id: \.self) { hours in
                    Text(Duration.seconds(hours * 3600).formatted(.units(allowed: [.hours], width: .wide)))
                        .tag(hours)
                }
            }
            DatePicker("Next reset", selection: $model.nextReset, displayedComponents: [.date, .hourAndMinute])
            if model.resetAnchor == nil {
                Label("Date not set yet: until then the menu shows no gauge, only the hours of the last 30 days.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Enter the plan")
        } footer: {
            Text("The cycle renews every month on this date. If the gauge does not match App Store Connect, check it again.")
        }
    }

    // MARK: - Helpers

    /// The Issuer ID is an identifier of the account: only its two ends are shown.
    nonisolated static func masked(_ issuerID: String) -> String {
        guard issuerID.count > 12 else { return String(repeating: "•", count: issuerID.count) }
        return String(issuerID.prefix(8)) + "-••••-••••-••••-••••••••" + String(issuerID.suffix(4))
    }

    private static let privateKeyType = UTType(filenameExtension: "p8") ?? .data
}
