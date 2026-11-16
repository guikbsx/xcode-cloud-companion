import SwiftUI

/// Where one account's alerts also go: its webhook address, what is sent there, and a test. The address is a secret:
/// once saved, only its host is shown.
struct WebhookSettingsSection: View {
    let session: AccountSession
    let service: WebhookService
    /// With several accounts each section is titled with its account's name.
    let showsName: Bool
    @State private var isEntering = false
    @State private var draft = ""
    @State private var confirmsRemoval = false
    @State private var isSending = false

    private var model: WebhookSettingsModel { session.webhook }
    private var showsSavedAddress: Bool { (model.hasAddress || !model.hasLoaded) && !isEntering }

    var body: some View {
        @Bindable var model = model
        Section {
            addressRow
                .skeleton(SkeletonRules.webhookAddress(hasLoaded: model.hasLoaded))
            Toggle(isOn: $model.choices.usage) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The plan runs low")
                    Text("At \(UsageFormat.percent(0.75)) and \(UsageFormat.percent(0.9)), and when the pace will not last.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("A build seems stuck", isOn: $model.choices.stuck)
            Toggle("A build failed", isOn: $model.choices.failed)
            Toggle("A build succeeded", isOn: $model.choices.succeeded)
            testRow
            DisclosureGroup("Message format") {
                format
            }
        } header: {
            Text(showsName ? String(localized: "Send elsewhere too: “\(session.name)”", comment: "Section title: where the alerts of one App Store Connect account also go") : String(localized: "Send elsewhere too"))
        } footer: {
            footer
        }
        .task { await model.load() }
        .confirmationDialog("Remove the webhook address?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                Task { await model.remove() }
            }
        } message: {
            Text("Cumulus stops sending to it, and the address is deleted from the Keychain.")
        }
    }

    // MARK: - Address

    @ViewBuilder
    private var addressRow: some View {
        if showsSavedAddress {
            LabeledContent {
                HStack {
                    Button("Replace…") {
                        draft = ""
                        model.clearAddressError()
                        isEntering = true
                    }
                    Button("Remove", role: .destructive) { confirmsRemoval = true }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Webhook address")
                    Text(verbatim: model.maskedAddress ?? "hooks.slack.com/••••••••")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Kept in the Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Webhook address")
                SecureField("Webhook address", text: $draft, prompt: Text(verbatim: "https://…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                    .onChange(of: draft) { model.clearAddressError() }
                if let error = model.addressError {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let message = model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("A Slack, Discord or any other address that takes a JSON message. Kept in the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if model.hasAddress {
                        Button("Cancel") { isEntering = false }
                    }
                    Button("Save") { save() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        // An empty field removes the address in the model; here only the button with its confirmation does, so a stray Return never does.
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await model.commit(draft) {
                draft = ""
                isEntering = false
            }
        }
    }

    // MARK: - Test

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Send a Test") {
                    isSending = true
                    Task {
                        await service.sendTest(accountID: session.id)
                        isSending = false
                    }
                }
                .disabled(!model.hasAddress || isSending)
                if isSending {
                    ProgressView().controlSize(.small)
                }
            }
            if let delivery = service.delivery(for: session.id) {
                Text(WebhookText.lastSend(delivery.result, at: delivery.date))
                    .font(.caption)
                    .foregroundStyle(delivery.result == .delivered ? Color.secondary : Color.orange)
            }
        }
    }

    // MARK: - Footer and format

    @ViewBuilder
    private var footer: some View {
        Text("Cumulus sends from this Mac: nothing leaves if it is off or if Cumulus is closed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var format: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The message is the banner’s title, its subtitle if it has one and its body, then the address of the build or of the Overview. It goes with a POST of JSON.")
            Text("Slack gets { \"text\": … } and Discord { \"content\": … }. Any other address gets:")
            Text(verbatim: WebhookText.formatExample)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("event is usage_alert, build_stuck, build_failed, build_succeeded or test. app, workflow and build are left out when the alert has none, and account is sent only when Cumulus follows several accounts.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
