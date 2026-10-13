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

    /// The agent picked last, remembered by its name.
    static let clientKey = "settings.agents.client"

    let model: AgentsSettingsModel
    @State private var picking: Picking?
    @State private var copiedClient: AgentClient?
    @State private var extensionError: String?
    @AppStorage(AgentsSettingsView.clientKey) private var clientName = AgentClient.claudeCode.rawValue

    private var client: AgentClient { AgentClient(rawValue: clientName) ?? .claudeCode }

    var body: some View {
        SettingsColumns(single: {
            intro
            clientPicker
            steps(for: client)
            abilities
        }) {
            intro
            abilities
        } trailing: {
            clientPicker
            steps(for: client)
        }
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

    private var clientPicker: some View {
        Section {
            Picker("Agent", selection: $clientName) {
                ForEach(AgentClient.allCases) { client in
                    Text(verbatim: client.name).tag(client.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var intro: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect an agent to Cumulus")
                        .font(.headline)
                    Text("Claude Code, Codex and Xcode’s agents read what the app already knows: builds, tests, the plan. They start a build only when the key is set to Read + Build, three times an hour per account at most, and you are told each time.")
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

    /// What to plug in for the agent picked, in order, each with its state and its action.
    private func steps(for client: AgentClient) -> some View {
        let checklist = model.checklist(for: client)
        return Section {
            step(1, isDone: model.commandState == .installed) {
                commandRow
            }
            ForEach(checklist.skills) { row in
                step(2, isDone: row.state == .installed) {
                    skillRow(row)
                }
            }
            step(client.keepsSkills ? 3 : 2, isDone: nil) {
                serverRow(client)
            }
        } header: {
            Text("For \(client.name)", comment: "Settings, Agents: title of what to install for the agent picked")
        } footer: {
            HStack(spacing: 10) {
                ProgressView(value: Double(checklist.done), total: Double(checklist.total))
                    .frame(width: 90)
                    .accessibilityHidden(true)
                Text("\(checklist.done) of \(checklist.total) in place", comment: "Settings, Agents: how many of the things an agent needs are installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if client.keepsSkills {
                    Button("Other Folder…") { picking = .skill(nil) }
                        .help("Install the skill in another agent’s skills folder")
                }
            }
        }
    }

    /// A numbered step: a tick once it is in place; `isDone` nil is a step whose state the app cannot read.
    private func step(_ number: Int, isDone: Bool?, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isDone == true {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BuildStatus.succeeded.textTint)
                        .frame(width: 22, height: 22)
                        .background(BuildStatus.succeeded.tint.opacity(0.18), in: .circle)
                } else {
                    Text(number.formatted())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: .circle)
                }
            }
            .accessibilityHidden(true)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private var commandRow: some View {
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
                Text("The command \(Text(verbatim: "cumulus").font(.body.monospaced()))", comment: "Settings, Agents: first thing to install, the argument is the command's name")
                Text(commandCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func skillRow(_ row: AgentsSettingsModel.SkillRow) -> some View {
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
                Text("The skill", comment: "Settings, Agents: second thing to install for an agent that keeps skills")
                Text(UsageFormat.dotted([skillCaption(row), String(localized: "It tells the agent when to use the command and how to read its answers.")]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func serverRow(_ client: AgentClient) -> some View {
        let snippet = client.snippet(command: model.locations.command)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The MCP server \(Text("(optional)").foregroundStyle(.secondary))", comment: "Settings, Agents: last thing to add for an agent; the argument says it is optional")
                    Text(UsageFormat.dotted([clientCaption(client), String(localized: "The agent then calls Cumulus as tools instead of a command.")]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(copiedClient == client ? "Copied" : "Copy") { copy(snippet, for: client) }
            }
            Text(verbatim: client.compactSnippet(command: model.locations.command))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if client == .claudeDesktop {
                HStack(alignment: .firstTextBaseline) {
                    Text(extensionError ?? String(localized: "Or as an extension: export it, then double-click the file to install it in Claude Desktop."))
                        .font(.caption)
                        .foregroundStyle(extensionError == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Export Extension…") { exportExtension() }
                }
            }
        }
    }

    /// Saves the Claude Desktop extension where the user says; choosing the place is what lets the sandbox write there.
    private func exportExtension() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        guard let data = MCPBundle.data(command: model.locations.command, appVersion: version) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MCPBundle.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            extensionError = nil
        } catch {
            extensionError = String(localized: "The extension could not be saved there.")
        }
    }

    /// What an agent may do once plugged in, said as it is: it reads, and it starts a build only under conditions.
    private var abilities: some View {
        Section("What an agent can do") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read", comment: "Settings, Agents: what an agent can do, first line")
                    Text("Builds, tests, issues and the plan. Nothing is changed on your App Store Connect account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "eye").foregroundStyle(.secondary)
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a build", comment: "Settings, Agents: what an agent can do, second line")
                    Text("Only when the account’s key is set to Read + Build, and three builds an hour per account at most. A notification tells you each time; Settings › Notifications can turn it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "play").foregroundStyle(.secondary)
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
