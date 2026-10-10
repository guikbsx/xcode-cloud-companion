import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets AI agents ask Cumulus about builds: the `cumulus` command on the PATH, its skill, and the MCP server.
struct AgentsSettingsView: View {
    /// Why the folder panel is open: to link something in the folder chosen, or to get back the right to unlink it.
    private enum Picking: Equatable {
        case command
        case skill(URL?)
        case removingCommand
        case removingSkill(URL)
    }

    let model: AgentsSettingsModel
    @State private var picking: Picking?
    @State private var copiedClient: AgentClient?

    var body: some View {
        Form {
            intro
            commandSection
            skillSection
            clientsSection
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .fileImporter(
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            allowedContentTypes: [.folder]
        ) { result in
            let picked = picking
            picking = nil
            guard case .success(let directory) = result, let picked else { return }
            Task {
                switch picked {
                case .command: await model.installCommand(in: directory)
                case .skill: await model.installSkill(in: directory)
                case .removingCommand: await model.removeCommand(grant: directory)
                case .removingSkill(let folder): await model.removeSkill(in: folder, grant: directory)
                }
            }
        }
        .fileDialogDefaultDirectory(defaultDirectory)
        .fileDialogBrowserOptions([.includeHiddenFiles])
        .fileDialogConfirmationLabel(isRemoving ? Text("Remove from Here") : Text("Install Here"))
    }

    private var isRemoving: Bool {
        switch picking {
        case .removingCommand, .removingSkill: true
        case .command, .skill, nil: false
        }
    }

    private var defaultDirectory: URL? {
        switch picking {
        case .command: model.suggestedCommandDirectory
        case .skill(let directory): directory ?? model.locations.home
        case .removingCommand: model.commandDirectory
        case .removingSkill(let directory): directory
        case nil: nil
        }
    }

    // MARK: - Sections

    private var intro: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cumulus for AI Agents")
                        .font(.headline)
                    Text("Claude Code, Codex and Xcode’s agents can ask Cumulus why a build failed, what is running, or how much of the plan is left. They read what the app already knows: nothing is changed on your account, and no build is ever launched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.accentColor)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var commandSection: some View {
        Section("Command") {
            LabeledContent {
                switch model.commandState {
                case .installed:
                    if let directory = model.commandDirectory, model.canChange(directory) {
                        Button("Remove") { Task { await model.removeCommand() } }
                    } else {
                        Button("Remove…") { picking = .removingCommand }
                    }
                case .broken:
                    Button("Repair…") { picking = .command }
                case .missing, .occupied:
                    Button("Install…") { picking = .command }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "cumulus")
                        .font(.body.monospaced())
                    Text(commandCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var commandCaption: String {
        let folder = model.commandDirectory.map(model.locations.abbreviated) ?? ""
        switch model.commandState {
        case .installed:
            return String(localized: "Installed in \(folder). Try “cumulus status” in Terminal.")
        case .broken:
            return String(localized: "The link in \(folder) leads to a copy of Cumulus that moved. Repair it to point here.")
        case .missing, .occupied:
            return String(localized: "Not installed. Choose a folder of your PATH, such as \(model.locations.abbreviated(model.suggestedCommandDirectory)).")
        }
    }

    private var skillSection: some View {
        Section {
            ForEach(model.skills) { row in
                LabeledContent {
                    switch row.state {
                    case .installed:
                        if model.canChange(row.directory) {
                            Button("Remove") { Task { await model.removeSkill(in: row.directory) } }
                        } else {
                            Button("Remove…") { picking = .removingSkill(row.directory) }
                        }
                    case .broken:
                        Button("Repair…") { picking = .skill(row.directory) }
                    case .missing, .occupied:
                        Button("Install…") { picking = .skill(row.directoryExists ? row.directory : nil) }
                            .disabled(!row.directoryExists)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.name)
                        Text(skillCaption(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Skill")
        } footer: {
            HStack {
                Text("The skill tells an agent when to use the command and how to read its answers. It follows the app’s updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Other Folder…") { picking = .skill(nil) }
            }
        }
    }

    private func skillCaption(_ row: AgentsSettingsModel.SkillRow) -> String {
        let folder = model.locations.abbreviated(row.directory)
        switch row.state {
        case .installed:
            return String(localized: "Installed in \(folder).")
        case .broken:
            return String(localized: "The link in \(folder) leads to a copy of Cumulus that moved. Repair it to point here.")
        case .occupied:
            return String(localized: "\(folder) already holds something named “cumulus”.")
        case .missing:
            return row.directoryExists
                ? String(localized: "Not installed. Its skills live in \(folder).")
                : String(localized: "No skills folder at \(folder). Create it first, or choose another folder.")
        }
    }

    private var clientsSection: some View {
        Section {
            ForEach(AgentClient.allCases) { client in
                let snippet = client.snippet(command: model.locations.command)
                let shown = client.compactSnippet(command: model.locations.command)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: client.name)
                            Text(clientCaption(client))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(copiedClient == client ? "Copied" : "Copy") { copy(snippet, for: client) }
                    }
                    Text(verbatim: shown)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("MCP Server")
        } footer: {
            Text("With the server, an agent calls Cumulus as tools instead of a command. Use it or the skill, whichever your agent supports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clientCaption(_ client: AgentClient) -> String {
        guard let file = client.configurationFile else {
            return String(localized: "Run this once in Terminal.")
        }
        return String(localized: "Merge this into \(file), then restart \(client.name).")
    }

    private func copy(_ text: String, for client: AgentClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedClient = client
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedClient == client { copiedClient = nil }
        }
    }
}
