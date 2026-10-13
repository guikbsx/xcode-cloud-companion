import Foundation

/// What sits where a link of ours should be.
nonisolated enum AgentLinkState: Equatable, Sendable {
    case missing
    case installed
    /// A link of ours that no longer leads to this app: the app moved, or another copy made it.
    case broken
    /// Something that is not a link to a Cumulus bundle: it is left alone.
    case occupied
}

nonisolated enum AgentLinkError: Error, Equatable, Sendable {
    case occupied
    case refused(String)

    var message: String {
        switch self {
        case .occupied:
            String(localized: "Something else is already there with that name. Remove it first, or choose another folder.")
        case .refused(let reason):
            String(localized: "macOS refused the change: \(reason)")
        }
    }
}

/// A symbolic link from a folder the user chose to something inside the app bundle. Because it is a link, what it
/// leads to follows the app's updates.
nonisolated struct AgentLink: Equatable, Sendable {
    var directory: URL
    var name: String
    var target: URL

    var url: URL { directory.appending(path: name) }

    /// Reads the link without following it; the sandbox lets the app look at a link it may not change.
    @concurrent func state() async -> AgentLinkState {
        let path = url.path(percentEncoded: false)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return (try? FileManager.default.attributesOfItem(atPath: path)) == nil ? .missing : .occupied
        }
        let resolved = URL(filePath: destination, relativeTo: directory).standardizedFileURL.path(percentEncoded: false)
        if Self.samePath(resolved, target.standardizedFileURL.path(percentEncoded: false)) {
            return .installed
        }
        return Self.leadsIntoACumulusBundle(resolved, toward: target) ? .broken : .occupied
    }

    /// Creates the link, replacing one of ours that broke. `directory` must be reachable: chosen by the user in a panel.
    @concurrent func install() async throws(AgentLinkError) {
        switch await state() {
        case .installed: return
        case .occupied: throw .occupied
        case .broken: try await remove()
        case .missing: break
        }
        do {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } catch {
            throw .refused(error.localizedDescription)
        }
    }

    /// Removes the link when it is one of ours; anything else stays.
    @concurrent func remove() async throws(AgentLinkError) {
        switch await state() {
        case .missing: return
        case .occupied: throw .occupied
        case .installed, .broken: break
        }
        guard unlink(url.path(percentEncoded: false)) == 0 else {
            throw .refused(String(cString: strerror(errno)))
        }
    }

    private static func samePath(_ first: String, _ second: String) -> Bool {
        first.trimmingSuffix("/") == second.trimmingSuffix("/")
    }

    /// A link that ends like ours, inside some `.app`: it was made by Cumulus, from another place.
    private static func leadsIntoACumulusBundle(_ path: String, toward target: URL) -> Bool {
        let components = target.standardizedFileURL.pathComponents
        guard let bundleIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return false }
        let tail = "/" + components[(bundleIndex + 1)...].joined(separator: "/")
        return path.trimmingSuffix("/").hasSuffix(tail) && path.contains(".app/")
    }
}

private nonisolated extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

/// Where the command and the skill live in the bundle, and the folders agents look into.
nonisolated struct AgentLocations: Equatable, Sendable {
    static let commandName = "cumulus"
    static let skillName = "cumulus"

    var bundle: URL
    /// The user's real home, not the sandbox container `NSHomeDirectory` answers with.
    var home: URL

    static var live: AgentLocations {
        AgentLocations(bundle: Bundle.main.bundleURL, home: URL(filePath: String(cString: getpwuid(getuid()).pointee.pw_dir), directoryHint: .isDirectory))
    }

    var command: URL { bundle.appending(path: "Contents/Helpers/cumulus") }
    var skill: URL { bundle.appending(path: "Contents/Resources/AgentSkill/cumulus", directoryHint: .isDirectory) }

    /// Folders of a usual PATH, the first that exists being the one the panel opens on.
    var commandDirectories: [URL] {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// `~/…` rather than the full path, as people write the folders of their home.
    func abbreviated(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let homePath = home.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }

    func commandLink(in directory: URL) -> AgentLink {
        AgentLink(directory: directory, name: Self.commandName, target: command)
    }

    func skillLink(in directory: URL) -> AgentLink {
        AgentLink(directory: directory, name: Self.skillName, target: skill)
    }
}

/// An agent that keeps its skills in a folder of the home.
nonisolated struct AgentSkillHost: Equatable, Sendable, Identifiable {
    var name: String
    /// Relative to the home, such as `.claude/skills`.
    var relativePath: String

    var id: String { relativePath }

    static let known = [
        AgentSkillHost(name: "Claude Code", relativePath: ".claude/skills"),
        AgentSkillHost(name: "Codex", relativePath: ".codex/skills"),
    ]

    func directory(home: URL) -> URL {
        home.appending(path: relativePath, directoryHint: .isDirectory)
    }
}

/// How each client is told about the MCP server: a command to run, or an entry to add to its configuration file.
nonisolated enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case xcode
    case claudeDesktop

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .xcode: "Xcode"
        case .claudeDesktop: "Claude Desktop"
        }
    }

    /// Nil for a client set up by a command; otherwise the file its entry goes into, from the home.
    var configurationFile: String? {
        switch self {
        case .claudeCode, .codex: nil
        case .xcode: "~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json"
        case .claudeDesktop: "~/Library/Application Support/Claude/claude_desktop_config.json"
        }
    }

    /// The snippet on one line, to show it; what is copied keeps its line breaks.
    func compactSnippet(command: URL) -> String {
        let snippet = snippet(command: command)
        return JSONValue(data: Data(snippet.utf8))?.compactString ?? snippet
    }

    func snippet(command: URL) -> String {
        let path = command.path(percentEncoded: false)
        switch self {
        case .claudeCode:
            return "claude mcp add --scope user cumulus -- \(Self.shellQuoted(path)) mcp"
        case .codex:
            return "codex mcp add cumulus -- \(Self.shellQuoted(path)) mcp"
        case .xcode, .claudeDesktop:
            let entry: JSONValue = ["mcpServers": ["cumulus": ["command": .string(path), "args": ["mcp"]]]]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// Whether a name an agent gave when it connected to `cumulus mcp` is this client's. Xcode's agent is Claude Code
    /// under another roof: unless its name says Xcode, its connections cannot be told from Claude Code's.
    func isConnection(named name: String) -> Bool {
        let name = name.lowercased()
        switch self {
        case .claudeCode: return name.contains("claude-code") || name.contains("claude code")
        case .codex: return name.contains("codex")
        case .xcode: return name.contains("xcode")
        case .claudeDesktop: return name.contains("claude-ai") || name.contains("claude-desktop") || name.contains("claude desktop")
        }
    }

    /// Quoted only when the shell would split or expand it, as a path with a space would be.
    static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+@:".contains($0)) }
        return safe && !text.isEmpty ? text : "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
