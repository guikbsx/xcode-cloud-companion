import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AgentConnectionsTests {
    private let now = Date(timeIntervalSince1970: 1_791_892_800)

    @Test func aConnectionKeepsTheNameAndTheLatestDate() {
        var connections = AgentConnections()
        connections.note("claude-code", at: now)
        connections.note("claude-code", at: now.addingTimeInterval(60))
        connections.note("  codex-mcp-client\n", at: now)

        #expect(connections.lastSeenByClient == ["claude-code": now.addingTimeInterval(60), "codex-mcp-client": now])
        #expect(connections.lastSeen { $0.contains("claude") } == now.addingTimeInterval(60))
        #expect(connections.lastSeen { $0.contains("xcode") } == nil)
    }

    @Test func aNameIsWhateverAClientSaysSoItIsKeptShortAndTheListToo() {
        var connections = AgentConnections()
        connections.note("", at: now)
        connections.note(String(repeating: "x", count: 500), at: now)
        #expect(connections.lastSeenByClient.keys.map(\.count) == [AgentConnections.maximumNameLength])

        for index in 0..<40 {
            connections.note("client-\(index)", at: now.addingTimeInterval(Double(index + 1)))
        }
        #expect(connections.lastSeenByClient.count == AgentConnections.maximumClients)
        #expect(connections.lastSeenByClient["client-39"] != nil && connections.lastSeenByClient["client-0"] == nil)
    }

    @Test func theCommandWritesWhatTheAppReads() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "connections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentConnectionsStore(directory: directory)
        #expect(store.load() == AgentConnections())

        store.note(client: "claude-ai", at: now)
        store.note(client: "claude-code", at: now.addingTimeInterval(5))

        #expect(store.load().lastSeenByClient == ["claude-ai": now, "claude-code": now.addingTimeInterval(5)])
    }

    @Test func initializeNotesTheClientAndWritesNothingElse() async throws {
        let environment = try await CLIFixture.environment()
        let server = MCPServer(environment: environment)

        _ = await server.response(to: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#.utf8))
        _ = await server.response(to: Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8))
        _ = await server.response(to: Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#.utf8))

        let file = environment.directory.appending(path: "AgentConnections.json")
        let saved = try JSONDecoder().decode(AgentConnections.self, from: Data(contentsOf: file))
        #expect(saved.lastSeenByClient == ["claude-code": CLIFixture.now])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("2.1") && !text.contains("capabilities"))
    }

    @Test func eachAgentKnowsItsOwnNameAndXcodeIsNotTakenForClaudeCode() {
        #expect(AgentClient.claudeCode.isConnection(named: "claude-code"))
        #expect(AgentClient.codex.isConnection(named: "codex-mcp-client"))
        #expect(AgentClient.claudeDesktop.isConnection(named: "claude-ai"))
        #expect(AgentClient.xcode.isConnection(named: "Xcode"))
        #expect(!AgentClient.xcode.isConnection(named: "claude-code"))
        #expect(!AgentClient.claudeDesktop.isConnection(named: "claude-code"))
        #expect(!AgentClient.claudeCode.isConnection(named: "claude-ai"))
        #expect(AgentClient.allCases.allSatisfy { !$0.isConnection(named: "cursor") })
    }
}

@MainActor
struct AgentConnectionStateTests {
    @Test func thePaneSaysWhichAgentConnectedAndWhen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "connections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "AgentConnectionStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentConnectionsStore(directory: directory)
        let seen = Date(timeIntervalSince1970: 1_791_892_800)
        store.note(client: "codex-mcp-client", at: seen)
        let locations = AgentLocations(bundle: directory.appending(path: "Cumulus.app"), home: directory)
        let model = AgentsSettingsModel(locations: locations, defaults: defaults, connectionsStore: store)

        #expect(model.lastConnection(of: .codex) == nil)
        await model.refresh()

        #expect(model.lastConnection(of: .codex) == seen)
        #expect(model.lastConnection(of: .claudeCode) == nil && model.lastConnection(of: .claudeDesktop) == nil)
    }
}
