import SwiftUI

/// What the sheet is about to do: pause a workflow, or resume it.
struct WorkflowPauseTarget: Identifiable {
    let workflow: CIWorkflow
    /// The state asked for: false pauses, true resumes.
    let enable: Bool

    var id: String { "\(enable ? "resume" : "pause")-\(workflow.id)" }
}

/// The confirmation before a workflow is paused or resumed: it names the workflow and says what follows.
struct WorkflowPauseSheet: View {
    let target: WorkflowPauseTarget
    let pauser: WorkflowPauser
    let onNotAllowed: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target.enable ? String(localized: "Resume") : String(localized: "Pause")) { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(pauser.isSending)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var title: String {
        target.enable
            ? String(localized: "Resume “\(target.workflow.name)”?")
            : String(localized: "Pause “\(target.workflow.name)”?")
    }

    private var explanation: String {
        target.enable
            ? String(localized: "Its start conditions apply again: a push, a pull request or a schedule can start builds, and builds can be started by hand. They use compute hours.")
            : String(localized: "While it is paused, no build of this workflow starts, neither on its own nor by hand. Nothing else about the workflow changes; you can resume it at any time.")
    }

    private func send() async {
        let outcome = await pauser.setEnabled(target.enable, workflow: target.workflow)
        if case .notAllowed = outcome {
            onNotAllowed()
        }
        if let text = outcome.message(wanted: target.enable) {
            message = text
        } else {
            dismiss()
        }
    }
}
