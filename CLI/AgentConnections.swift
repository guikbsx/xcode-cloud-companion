import Foundation

/// Which agents connected to `cumulus mcp`, and when. Only the name an agent gives of itself at `initialize` and a
/// date are kept: the app reads them to say that a server is plugged in, which it cannot read from an agent's own
/// configuration.
nonisolated struct AgentConnections: Codable, Equatable, Sendable {
    static let maximumClients = 20
    static let maximumNameLength = 80

    private(set) var lastSeenByClient: [String: Date] = [:]

    /// The oldest go first when there are too many: a name is whatever a client says, and the file must stay small.
    mutating func note(_ client: String, at date: Date) {
        let name = String(client.filter { !$0.isNewline && $0 != "\0" }.trimmingCharacters(in: .whitespaces).prefix(Self.maximumNameLength))
        guard !name.isEmpty else { return }
        lastSeenByClient[name] = date
        while lastSeenByClient.count > Self.maximumClients, let oldest = lastSeenByClient.min(by: { $0.value < $1.value }) {
            lastSeenByClient[oldest.key] = nil
        }
    }

    /// The latest connection among the clients whose name `matches`.
    func lastSeen(where matches: (String) -> Bool) -> Date? {
        lastSeenByClient.filter { matches($0.key) }.values.max()
    }
}

/// At the root of the shared container, beside the registry of accounts: written by the command, read by the app.
nonisolated struct AgentConnectionsStore: Sendable {
    var fileURL: URL

    init(directory: URL) {
        fileURL = directory.appending(path: "AgentConnections.json")
    }

    func load() -> AgentConnections {
        guard let data = try? Data(contentsOf: fileURL) else { return AgentConnections() }
        return (try? JSONDecoder().decode(AgentConnections.self, from: data)) ?? AgentConnections()
    }

    /// Best effort: a connection that cannot be noted is still a connection.
    func note(client: String, at date: Date) {
        var connections = load()
        connections.note(client, at: date)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(connections).write(to: fileURL, options: [.atomic])
    }
}
