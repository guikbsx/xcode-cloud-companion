import SwiftUI
import UniformTypeIdentifiers

/// One account's settings, on the right of the Accounts tab: its name, its API key, its plan.
struct AccountDetailView: View {
    let accounts: AccountsModel
    let session: AccountSession
    @Bindable var model: SettingsModel
    let requestRemoval: () -> Void
    @State private var showsGuides = false
    @State private var isImportingExport = false
    @State private var name: String
    @FocusState private var nameIsFocused: Bool

    init(accounts: AccountsModel, session: AccountSession, requestRemoval: @escaping () -> Void) {
        self.accounts = accounts
        self.session = session
        self.model = session.settings
        self.requestRemoval = requestRemoval
        _name = State(initialValue: session.name)
    }

    private var showsKeyGuide: Bool { !model.hasStoredKey || showsGuides }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(AccountsModel.defaultName(among: [])))
                    .focused($nameIsFocused)
                    .onSubmit(renameIfNeeded)
                    .onChange(of: nameIsFocused) { _, isFocused in
                        if !isFocused { renameIfNeeded() }
                    }
            }
            if model.hasStoredKey {
                connectedHeader
            } else {
                KeyIntroSection()
            }
            if showsKeyGuide {
                KeyGuideSection(issuerID: model.issuerID)
            }
            if model.hasStoredKey {
                storedKey
                foundApps
            } else {
                KeyEntrySection(
                    keyID: $model.keyID, issuerID: $model.issuerID, keyAccess: $model.keyAccess,
                    fileName: { if case .imported(let fileName) = model.keyState { fileName } else { nil } }(),
                    errorMessage: model.errorMessage,
                    refusal: { if case .failed(let message) = model.connectionState { message } else { nil } }(),
                    isTesting: model.connectionState == .testing, canSave: model.canSave,
                    importKey: model.importPrivateKey(from:), save: { Task { await model.saveAndTestConnection() } }
                )
            }
            planIntro
            if showsKeyGuide {
                PlanGuideSection(issuerID: model.issuerID)
            }
            planInput
            billedMinutes
            if model.hasStoredKey {
                Section {
                    Button(showsGuides ? "Hide the guides" : "Where to find the key and the reset date?") {
                        showsGuides.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
            Section {
                // In the section rather than its footer, where a grouped form may not pass clicks through.
                Button("Remove Account…", role: .destructive, action: requestRemoval)
                if let removalError = accounts.removalError {
                    Label(removalError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Its key leaves the keychain, and its cached builds, imported usage exports, plan and reset date are deleted. The other accounts are not touched.")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .fileImporter(isPresented: $isImportingExport, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result {
                Task { await accounts.importUsageExport(at: url, from: session) }
            }
        }
    }

    // MARK: - Billed minutes

    /// Apple's exact minutes, from the usage exports imported for this account.
    private var billedMinutes: some View {
        let usage = session.usageStore
        return Section {
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
            HStack {
                Spacer()
                Button("Import an Export…") { isImportingExport = true }
            }
        } header: {
            Text("Billed Minutes")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Without an export, the usage shown is an estimate computed from the builds’ actions.")
                Text("For Apple's exact figures: in **Xcode Cloud › Usage**, click **Export as CSV**. The app picks the file up from Downloads on its own.")
                if accounts.hasSeveral {
                    Text("An export goes to the account whose apps it lists.")
                }
            }
        }
    }

    /// A blank name is not a name: the field goes back to the one the account has.
    private func renameIfNeeded() {
        accounts.rename(session.id, to: name)
        name = session.name
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
            KeyAccessPicker(keyAccess: $model.keyAccess)
            HStack {
                Spacer()
                Button("Test Connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.connectionState == .testing)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
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

    /// The Issuer ID is an identifier of the account: only its two ends are shown.
    nonisolated static func masked(_ issuerID: String) -> String {
        guard issuerID.count > 12 else { return String(repeating: "•", count: issuerID.count) }
        return String(issuerID.prefix(8)) + "-••••-••••-••••-••••••••" + String(issuerID.suffix(4))
    }
}

/// A new account: its name, how to create its key, and the key itself. The account only exists once Apple accepted it.
struct NewAccountView: View {
    @Bindable var form: NewAccountModel
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $form.name, prompt: Text(AccountsModel.defaultName(among: [])))
            } header: {
                Text("New Account")
            } footer: {
                Text("One account per App Store Connect team, each with its own API key and plan. Every account stays up to date and sends its notifications; the menu and the window show one at a time.")
            }
            KeyIntroSection()
            KeyGuideSection(issuerID: form.issuerID)
            KeyEntrySection(
                keyID: $form.keyID, issuerID: $form.issuerID, keyAccess: $form.keyAccess,
                fileName: form.keyFileName, errorMessage: form.errorMessage, refusal: form.refusal,
                isTesting: form.isTesting, canSave: form.canSave,
                importKey: form.importPrivateKey(from:), save: save, cancel: cancel
            )
        }
        .formStyle(.grouped)
    }
}

/// Why the app needs a key, before one is entered.
private struct KeyIntroSection: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Store Connect API Key")
                        .font(.headline)
                    Text("The app reads your Xcode Cloud builds with an API key. It only launches a build or pauses a workflow when you ask it to, and the key stays in your keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct KeyGuideSection: View {
    let issuerID: String

    var body: some View {
        Section {
            GuideStep(number: 1) {
                Text("In App Store Connect, open **Users and Access › Integrations › App Store Connect API**, **Team Keys** tab.")
                Link("Open in App Store Connect ↗", destination: AppStoreConnectLinks.integrations(teamID: issuerID))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            GuideStep(number: 2) {
                Text("Click **+**, name the key “Cumulus” and give it **App Manager** access to launch builds from Cumulus, or **Developer** access to only read them.")
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
}

private struct PlanGuideSection: View {
    let issuerID: String

    var body: some View {
        Section("Where to find them") {
            GuideStep(number: 1) {
                Text("In App Store Connect, open **Xcode Cloud › Usage**.")
                Link("Open Usage ↗", destination: AppStoreConnectLinks.xcodeCloudUsage(teamID: issuerID))
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
}

/// What the key may do. The app assumes it may launch builds; the first refusal from Apple switches it to Read only.
private struct KeyAccessPicker: View {
    @Binding var keyAccess: KeyAccess

    var body: some View {
        Picker(selection: $keyAccess) {
            Text("Read only").tag(KeyAccess.readOnly)
            Text("Read + Build").tag(KeyAccess.canLaunch)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Key access")
                Text("Read + Build shows the buttons that launch builds and pause workflows; it needs the App Manager role. If Apple refuses, Cumulus switches to Read only on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The `.p8` file, the Key ID and the Issuer ID, for a new account or for one whose key went missing.
private struct KeyEntrySection: View {
    @Binding var keyID: String
    @Binding var issuerID: String
    @Binding var keyAccess: KeyAccess
    let fileName: String?
    let errorMessage: String?
    /// Apple's words when it refused the key.
    let refusal: String?
    let isTesting: Bool
    let canSave: Bool
    let importKey: (URL) -> Void
    let save: () -> Void
    var cancel: (() -> Void)?
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                if let fileName {
                    Label(fileName, systemImage: "doc.badge.checkmark")
                } else {
                    Text("Drop the `.p8` file here")
                }
                Button("Choose a File…") { isImporting = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(isDropTargeted ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "p8" }) else { return false }
                importKey(url)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.privateKeyType]) { result in
                if case .success(let url) = result {
                    importKey(url)
                }
            }
            TextField("Key ID", text: $keyID, prompt: Text("Filled in from the .p8 file", comment: "Placeholder of the Key ID field before a key file is added"))
            Text("Normally filled in on its own when you add the `.p8` file: its name, `AuthKey_<Key ID>.p8`, holds the Key ID. Type it only if the file was renamed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Issuer ID", text: $issuerID, prompt: Text(verbatim: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
            KeyAccessPicker(keyAccess: $keyAccess)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if isTesting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Contacting App Store Connect…")
                }
            } else if let refusal {
                VStack(alignment: .leading, spacing: 3) {
                    Label("App Store Connect refuses this key.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fontWeight(.semibold)
                    Text("The Issuer ID or the Key ID may not match the file, or the key was revoked. Check step 3.")
                        .font(.callout)
                    Text(refusal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Enter the key")
        } footer: {
            HStack {
                Spacer()
                if let cancel {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button("Save and Test", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
    }

    private static let privateKeyType = UTType(filenameExtension: "p8") ?? .data
}
