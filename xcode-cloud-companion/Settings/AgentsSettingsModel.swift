import Foundation
import Observation

/// The Agents tab: where the `cumulus` command and its skill are linked, and what remains to be done.
@Observable
final class AgentsSettingsModel {
    struct SkillRow: Identifiable, Equatable {
        var id: String { directory.path(percentEncoded: false) }
        var name: String
        var directory: URL
        var directoryExists: Bool
        var state: AgentLinkState
    }

    private(set) var commandDirectory: URL?
    private(set) var commandState = AgentLinkState.missing
    private(set) var skills: [SkillRow] = []
    private(set) var errorMessage: String?
    /// The agents that connected to `cumulus mcp`, as the command noted them.
    private(set) var connections = AgentConnections()

    let locations: AgentLocations
    private let defaults: UserDefaults
    private let connectionsStore: AgentConnectionsStore

    init(
        locations: AgentLocations = .live, defaults: UserDefaults = .standard,
        connectionsStore: AgentConnectionsStore = AgentConnectionsStore(directory: SharedContainer.applicationSupport)
    ) {
        self.locations = locations
        self.defaults = defaults
        self.connectionsStore = connectionsStore
    }

    /// When the agent last connected to the MCP server; nil while it never did, or cannot be told from another.
    func lastConnection(of client: AgentClient) -> Date? {
        connections.lastSeen(where: client.isConnection(named:))
    }

    /// Where the open panel starts for the command: the first usual PATH folder that exists.
    var suggestedCommandDirectory: URL {
        locations.commandDirectories.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? locations.home
    }

    /// Looks at every link again; what it finds may have changed outside the app.
    func refresh() async {
        connections = await Self.connections(in: connectionsStore)
        var found: (URL, AgentLinkState)?
        for directory in commandCandidates {
            let state = await locations.commandLink(in: directory).state()
            if state == .installed || state == .broken {
                found = (directory, state)
                break
            }
        }
        commandDirectory = found?.0
        commandState = found?.1 ?? .missing

        var rows: [SkillRow] = []
        for (name, directory) in skillFolders {
            rows.append(SkillRow(
                name: name, directory: directory,
                directoryExists: await Self.directoryExists(directory),
                state: await locations.skillLink(in: directory).state()
            ))
        }
        skills = rows
    }

    // MARK: - Command

    /// `directory` comes from a panel: the user's choice is what lets the sandbox write there.
    func installCommand(in directory: URL) async {
        await change(directory) { [locations] () async throws(AgentLinkError) in
            try await locations.commandLink(in: directory).install()
        }
        if errorMessage == nil {
            defaults.set(directory.path(percentEncoded: false), forKey: Keys.commandDirectory)
        }
        await refresh()
    }

    /// `grant` is the folder as a panel just returned it, for a link the app no longer holds the right to change.
    func removeCommand(grant: URL? = nil) async {
        guard let directory = commandDirectory else { return }
        await change(directory, grant: grant) { [locations] () async throws(AgentLinkError) in
            try await locations.commandLink(in: directory).remove()
        }
        await refresh()
    }

    // MARK: - Skill

    func installSkill(in directory: URL) async {
        await change(directory) { [locations] () async throws(AgentLinkError) in
            try await locations.skillLink(in: directory).install()
        }
        if errorMessage == nil, !skillFolders.contains(where: { $0.directory.standardizedFileURL == directory.standardizedFileURL }) {
            defaults.set(extraSkillDirectories + [directory.path(percentEncoded: false)], forKey: Keys.skillDirectories)
        }
        await refresh()
    }

    func removeSkill(in directory: URL, grant: URL? = nil) async {
        await change(directory, grant: grant) { [locations] () async throws(AgentLinkError) in
            try await locations.skillLink(in: directory).remove()
        }
        if errorMessage == nil {
            defaults.set(extraSkillDirectories.filter { $0 != directory.path(percentEncoded: false) }, forKey: Keys.skillDirectories)
        }
        await refresh()
    }

    /// Whether the app still holds the right to change `directory`, kept from the day the user chose it.
    func canChange(_ directory: URL) -> Bool {
        bookmarks[directory.path(percentEncoded: false)] != nil
    }

    // MARK: - Private

    private enum Keys {
        static let commandDirectory = "agents.commandDirectory"
        static let skillDirectories = "agents.skillDirectories"
        static let bookmarks = "agents.bookmarks"
    }

    private var commandCandidates: [URL] {
        let remembered = defaults.string(forKey: Keys.commandDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
        var seen: Set<String> = []
        return ([remembered].compactMap(\.self) + locations.commandDirectories).filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }

    private var extraSkillDirectories: [String] {
        defaults.stringArray(forKey: Keys.skillDirectories) ?? []
    }

    private var skillFolders: [(name: String, directory: URL)] {
        let known = AgentSkillHost.known.map { ($0.name, $0.directory(home: locations.home)) }
        let extra = extraSkillDirectories.map { path in
            (URL(filePath: path).deletingLastPathComponent().lastPathComponent, URL(filePath: path, directoryHint: .isDirectory))
        }
        return known + extra.filter { extra in !known.contains { $0.1.standardizedFileURL == extra.1.standardizedFileURL } }
    }

    private var bookmarks: [String: Data] {
        defaults.dictionary(forKey: Keys.bookmarks) as? [String: Data] ?? [:]
    }

    /// Runs `operation` with the folder open to the sandbox: through a panel's grant, or the bookmark kept from an earlier one.
    private func change(_ directory: URL, grant: URL? = nil, _ operation: @escaping @Sendable () async throws(AgentLinkError) -> Void) async {
        let path = directory.path(percentEncoded: false)
        var isStale = false
        let remembered = bookmarks[path].flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        }
        let scoped = grant ?? remembered ?? directory
        let isAccessing = scoped.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { scoped.stopAccessingSecurityScopedResource() }
        }
        if isAccessing, remembered == nil || isStale,
           let data = try? scoped.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var saved = bookmarks
            saved[scoped.path(percentEncoded: false)] = data
            defaults.set(saved, forKey: Keys.bookmarks)
        }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.message
        }
    }

    @concurrent private static func connections(in store: AgentConnectionsStore) async -> AgentConnections {
        store.load()
    }

    @concurrent private static func directoryExists(_ directory: URL) async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

extension AgentClient {
    /// Whether the agent keeps skills in a folder of the home: Claude Code and Codex do, the others only speak MCP.
    var keepsSkills: Bool {
        AgentSkillHost.known.contains { $0.name == name }
    }
}

extension AgentsSettingsModel {
    /// What there is to plug in for one agent, and how much of it is in place. The MCP server is added by hand in the
    /// agent's own configuration: nothing of it can be read from here, so it is not counted.
    struct Checklist: Equatable {
        /// The agent's own skills folder, then the folders the user added; empty for an agent without skills.
        let skills: [SkillRow]
        let done: Int
        let total: Int
    }

    func checklist(for client: AgentClient) -> Checklist {
        let known = Set(AgentSkillHost.known.map(\.name))
        let rows = client.keepsSkills ? skills.filter { $0.name == client.name || !known.contains($0.name) } : []
        let commandDone = commandState == .installed ? 1 : 0
        let skillDone = rows.contains { $0.state == .installed } ? 1 : 0
        return Checklist(skills: rows, done: commandDone + (client.keepsSkills ? skillDone : 0), total: client.keepsSkills ? 2 : 1)
    }
}

