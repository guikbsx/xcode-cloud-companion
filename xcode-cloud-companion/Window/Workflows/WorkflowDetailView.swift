import SwiftUI

/// The sheet of a workflow: how it starts, where it runs, what it does. Read only.
struct WorkflowDetailView: View {
    let model: WorkflowDetailModel
    var tests: WorkflowTestsModel?
    var openBuildTests: (String) -> Void = { _ in }
    /// Pauses or resumes this workflow; nil while the key is declared read-only.
    var togglePause: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.info.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        ForEach(model.info) { InfoItem(key: $0.title, value: $0.value, help: $0.help) }
                    }
                    .cumulusGroup()
                }
                if !model.startConditions.isEmpty {
                    section("Start conditions") {
                        ForEach(model.startConditions) { condition in
                            HStack(alignment: .firstTextBaseline) {
                                Text(condition.title).fontWeight(.semibold)
                                Spacer(minLength: 12)
                                Text(condition.value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if !model.actions.isEmpty {
                    section("Actions") {
                        ForEach(model.actions) { action in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.name).fontWeight(.semibold)
                                if !action.facts.isEmpty {
                                    Text(action.facts).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let tests {
                    WorkflowTestsSection(workflowID: model.id, model: tests, openBuild: openBuildTests)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.productName ?? "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.system(size: 30, weight: .bold, design: .rounded))
            HStack(spacing: 6) {
                if let isEnabled = model.isEnabled {
                    CapsuleTag(
                        text: isEnabled ? String(localized: "Enabled") : String(localized: "Paused"),
                        systemImage: isEnabled ? "checkmark" : "pause",
                        tint: isEnabled ? BuildStatus.succeeded.tint : BuildStatus.skipped.tint
                    )
                }
                if model.isLocked == true {
                    CapsuleTag(text: String(localized: "Locked"), systemImage: "lock")
                }
                if let togglePause, let isEnabled = model.isEnabled, model.isLocked != true {
                    Button(isEnabled ? "Pause…" : "Resume…", systemImage: isEnabled ? "pause.fill" : "play.fill", action: togglePause)
                        .controlSize(.small)
                        .padding(.leading, 6)
                }
            }
            if togglePause != nil, model.isLocked == true {
                Text(WorkflowPauser.lockedMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let description = model.description {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }
}
