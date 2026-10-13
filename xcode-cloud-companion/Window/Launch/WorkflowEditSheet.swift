import SwiftUI

struct WorkflowEditTarget: Identifiable {
    let workflow: CIWorkflow

    var id: String { "edit-\(workflow.id)" }
}

/// The sheet that changes a workflow: only what the API exposes and the app can show safely. Triggers, actions and
/// environment variables stay in Xcode or App Store Connect, and the sheet says so.
struct WorkflowEditSheet: View {
    let target: WorkflowEditTarget
    let editor: WorkflowEditor
    let onSaved: (CIWorkflow) -> Void
    let onNotAllowed: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var clean = false
    @State private var xcodeVersionID: String?
    @State private var macOSVersionID: String?
    @State private var message: String?
    /// The versions have been asked for, answered or not.
    @State private var versionsEnded = false

    private var workflow: CIWorkflow { target.workflow }

    private var request: WorkflowUpdateRequest {
        WorkflowUpdateRequest.changes(from: workflow, name: name, description: description, clean: clean, xcodeVersionID: xcodeVersionID, macOSVersionID: macOSVersionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change “\(workflow.name)”").font(.title3.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $name).labelsHidden()
                }
                GridRow {
                    Text("Description")
                    TextField("Description", text: $description, prompt: Text("What this workflow is for")).labelsHidden()
                }
                GridRow {
                    Text("Xcode")
                    xcodePicker
                }
                GridRow {
                    Text("macOS")
                    macOSPicker
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Toggle("Always make a clean build", isOn: $clean)
                }
            }
            Label("Start conditions, actions and environment variables are changed in Xcode or App Store Connect.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!request.isWellFormed || editor.isSending)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: adopt)
        .task {
            await editor.loadVersions(currentXcodeVersionID: workflow.xcodeVersionID)
            versionsEnded = true
        }
        .onChange(of: xcodeVersionID) { _, id in
            guard let id else { return }
            Task {
                await editor.loadMacOSVersions(xcodeVersionID: id)
                keepMacOSVersionValid(for: id)
            }
        }
        .onChange(of: editor.macOSVersionsByXcode.count) {
            if let xcodeVersionID { keepMacOSVersionValid(for: xcodeVersionID) }
        }
    }

    @ViewBuilder
    private var xcodePicker: some View {
        if let versions = editor.xcodeVersions {
            Picker("Xcode", selection: $xcodeVersionID) {
                if let current = workflow.xcodeVersionID, !versions.contains(where: { $0.id == current }) {
                    Text(workflow.xcodeVersionName ?? String(localized: "Current version")).tag(Optional(current))
                }
                ForEach(WorkflowEditor.ordered(versions)) { version in
                    Text(Self.label(version, latest: version.id == XcodeVersionCheck.latestPublic(in: versions)?.id)).tag(Optional(version.id))
                }
            }
            .labelsHidden()
        } else if editor.versionsFailed {
            Text(workflow.xcodeVersionName ?? String(localized: "Unknown")).foregroundStyle(.secondary)
            Text("The list of versions couldn’t be read: the version stays as it is.").font(.caption).foregroundStyle(.secondary)
        } else if versionsEnded {
            Text(workflow.xcodeVersionName ?? String(localized: "Unknown")).foregroundStyle(.secondary)
        } else {
            versionSkeleton("Xcode", name: workflow.xcodeVersionName ?? "Xcode 27.1")
        }
    }

    /// The menu as it will stand, over the version the workflow uses, until the lists are read.
    private func versionSkeleton(_ label: LocalizedStringKey, name: String) -> some View {
        Picker(label, selection: .constant(name)) {
            Text(verbatim: name).tag(name)
        }
        .labelsHidden()
        .skeleton(true)
    }

    @ViewBuilder
    private var macOSPicker: some View {
        if let xcodeVersionID, let versions = editor.macOSVersionsByXcode[xcodeVersionID], !versions.isEmpty {
            Picker("macOS", selection: $macOSVersionID) {
                ForEach(versions) { version in
                    Text(version.name).tag(Optional(version.id))
                }
            }
            .labelsHidden()
        } else if !versionsEnded, xcodeVersionID != nil {
            versionSkeleton("macOS", name: workflow.macOSVersionName ?? "macOS 27.0")
        } else {
            Text(workflow.macOSVersionName ?? String(localized: "Unknown")).foregroundStyle(.secondary)
        }
    }

    static func label(_ version: CIXcodeVersion, latest: Bool) -> String {
        latest ? String(localized: "\(version.name) (latest)", comment: "The newest public Xcode in the version menu") : version.name
    }

    private func adopt() {
        name = workflow.name
        description = workflow.description ?? ""
        clean = workflow.clean ?? false
        xcodeVersionID = workflow.xcodeVersionID
        macOSVersionID = workflow.macOSVersionID
    }

    /// A macOS version Apple does not offer for the Xcode picked would be refused: the first one offered takes its place.
    private func keepMacOSVersionValid(for xcodeVersionID: String) {
        guard let versions = editor.macOSVersionsByXcode[xcodeVersionID], !versions.isEmpty else { return }
        if !versions.contains(where: { $0.id == macOSVersionID }) {
            macOSVersionID = versions.first?.id
        }
    }

    private func save() async {
        let outcome = await editor.save(request, workflow: workflow)
        switch outcome {
        case .saved(let workflow):
            onSaved(workflow)
            dismiss()
        case .notAllowed:
            onNotAllowed()
            message = outcome.message
        case .uncertain(let read?):
            // The sheet shows what Apple holds now, so a second try starts from the truth.
            onSaved(read)
            message = outcome.message
        default:
            message = outcome.message
        }
    }
}
