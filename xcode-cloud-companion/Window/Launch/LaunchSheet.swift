import SwiftUI

/// What the sheet is about to do: start a workflow on a branch, or rebuild a run.
struct LaunchTarget: Identifiable {
    enum Mode {
        case launch(CIWorkflow, preferredReference: String?)
        case rebuild(CIBuildRun, CIWorkflow)
    }

    let mode: Mode
    let productID: String

    var id: String {
        switch mode {
        case .launch(let workflow, _): "launch-\(workflow.id)"
        case .rebuild(let run, _): "rebuild-\(run.id)"
        }
    }

    var workflow: CIWorkflow {
        switch mode {
        case .launch(let workflow, _), .rebuild(_, let workflow): workflow
        }
    }
}

/// The confirmation before anything is sent: it names the workflow and the branch, and says what cannot be undone.
struct LaunchSheet: View {
    let target: LaunchTarget
    let launcher: BuildLauncher
    let onStarted: (CIBuildRun) -> Void
    let onNotAllowed: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var references: [GitReference]?
    @State private var referenceID: String?
    @State private var clean = false
    @State private var result: LaunchOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            if case .launch = target.mode {
                referencePicker
            }
            Toggle("Clean build", isOn: $clean)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let result, let message = Self.message(for: result) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSend)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { await loadReferences() }
    }

    private var title: String {
        switch target.mode {
        case .launch(let workflow, _): String(localized: "Launch “\(workflow.name)”?")
        case .rebuild(let run, let workflow): String(localized: "Rebuild \(run.number.map { "#\($0)" } ?? "this build") of “\(workflow.name)”?")
        }
    }

    private var confirmTitle: String {
        if case .rebuild = target.mode { String(localized: "Rebuild") } else { String(localized: "Launch") }
    }

    private var explanation: String {
        switch target.mode {
        case .launch:
            String(localized: "Xcode Cloud starts a manual build and uses compute hours. The workflow needs a manual start condition that matches this branch. Cumulus cannot cancel it.")
        case .rebuild:
            String(localized: "Xcode Cloud repeats this build and uses compute hours. Cumulus cannot cancel it.")
        }
    }

    private var canSend: Bool {
        if launcher.isLaunching { return false }
        if case .launch = target.mode { return referenceID != nil }
        return true
    }

    @ViewBuilder
    private var referencePicker: some View {
        if let references {
            if references.isEmpty {
                Text("No branch or tag was found for this workflow.").foregroundStyle(.secondary)
            } else {
                Picker("Branch or tag", selection: $referenceID) {
                    ForEach(references) { reference in
                        Text(reference.name).tag(Optional(reference.id))
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading branches…").foregroundStyle(.secondary)
            }
        }
    }

    private func loadReferences() async {
        guard case .launch(let workflow, let preferred) = target.mode else { return }
        let loaded = await launcher.references(for: workflow.id) ?? []
        references = loaded
        referenceID = loaded.first { $0.name == preferred }?.id
            ?? loaded.first { ["main", "master", "develop"].contains($0.name) }?.id
            ?? loaded.first?.id
    }

    private func send() async {
        let request: BuildRunRequest
        switch target.mode {
        case .launch(let workflow, _):
            guard let referenceID else { return }
            request = .launch(workflowID: workflow.id, source: .gitReference(id: referenceID), clean: clean)
        case .rebuild(let run, let workflow):
            request = .rebuild(buildRunID: run.id, workflowID: workflow.id, clean: clean)
        }
        let outcome = await launcher.launch(request, productID: target.productID, workflowName: target.workflow.name)
        switch outcome {
        case .started(let run):
            onStarted(run)
            dismiss()
        case .uncertain(let found?):
            onStarted(found)
            dismiss()
        case .notAllowed:
            result = outcome
            onNotAllowed()
        default:
            result = outcome
        }
    }

    static func message(for outcome: LaunchOutcome) -> String? {
        switch outcome {
        case .started: nil
        case .notAllowed(let message): message
        case .refused(let message, let pointsAtSource):
            pointsAtSource ? UsageFormat.dotted([message, String(localized: "Pick another branch or tag.")]) : message
        case .rateLimited: String(localized: "Apple’s hourly request limit is reached. Nothing was started; try again later.")
        case .failed(let message): message
        case .uncertain(let found):
            found == nil ? String(localized: "Apple did not confirm the launch, and the build list shows no new build. Nothing seems to have started; you can try again.") : nil
        }
    }
}
