import Foundation
import Testing
@testable import XcodeCloudCompanion

struct ProStatusTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "cumulus-pro-\(UUID().uuidString)")
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    @Test func theStateIsWrittenOnceAndAgainOnlyWhenItChanges() {
        let store = ProStatusStore(directory: directory)
        #expect(store.load() == nil)

        store.record(isActive: false, now: now)
        #expect(store.load() == ProStatus(isActive: false, writtenAt: now))

        store.record(isActive: false, now: now.addingTimeInterval(60))
        #expect(store.load()?.writtenAt == now, "the same answer is not written twice")

        store.record(isActive: true, now: now.addingTimeInterval(120))
        #expect(store.load() == ProStatus(isActive: true, writtenAt: now.addingTimeInterval(120)))
        #expect(store.fileURL.lastPathComponent == "Pro.json")
    }

    @Test func anUnreadableFileIsNoPro() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appending(path: "Pro.json"))

        let refusal = try #require(ProGate.refusal(in: directory))
        #expect(refusal.code == .proRequired && refusal.suggestions.first == "Open the Cumulus app, then try again.")
    }

    @MainActor
    @Test func theAppIsToldTheStateAfterEachReadingAndNeverWithAPinnedOne() async {
        var told: [Bool] = []
        let source = StubProSource()
        let store = ProStore(source: source)
        store.onRead = { told.append($0.isActive) }

        await store.refresh()
        await source.set([.verified(ProTransaction(product: .lifetime, purchaseDate: now))])
        await store.refresh()
        #expect(told == [false, true])

        let pinned = ProStore(source: source, forced: .free)
        pinned.onRead = { told.append($0.isActive) }
        await pinned.refresh()
        #expect(told == [false, true], "a pinned state must not reach the file the real command reads")
    }
}

struct ProCommandTests {
    private func run(_ arguments: [String], pro: Bool?) async throws -> CLIResult {
        await CumulusCLI.run(arguments: arguments + ["--json"], environment: try await CLIFixture.environment(pro: pro))
    }

    private static let locked: [[String]] = [
        ["accounts"], ["apps"], ["builds"], ["build", "Alpha#44"], ["workflows"], ["usage"], ["open", "Alpha#44"], ["refresh"], ["run", "CI", "--yes"],
        ["testflight", "Alpha#44"], ["testflight", "give", "Alpha#44", "--group", "QA", "--yes"], ["testflight", "expire", "Alpha#44", "--yes"],
    ]

    @Test(arguments: locked)
    func withoutProEveryCommandButStatusIsRefused(arguments: [String]) async throws {
        let result = try await run(arguments, pro: false)

        #expect(result.exitCode == 9 && result.stdout.isEmpty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "PRO_REQUIRED")
        #expect(error["message"] as? String == "Cumulus Pro is required.")
        let suggestions = try #require(error["suggestions"] as? [String])
        #expect(suggestions.first?.contains("Settings › Cumulus Pro") == true)
        #expect(suggestions.last == "'cumulus status' works without Cumulus Pro.")
    }

    @Test func statusHelpAndVersionAnswerWithoutPro() async throws {
        let status = try await run(["status"], pro: false)
        #expect(status.exitCode == 0 && status.stderr.isEmpty)
        #expect(try CLIFixture.json(status).meta["account"] as? String == CLIFixture.account.name)

        let environment = try await CLIFixture.environment(pro: false)
        let help = await CumulusCLI.run(arguments: ["help"], environment: environment)
        #expect(help.exitCode == 0 && help.stdout.contains("PRO_REQUIRED"))
        #expect(await CumulusCLI.run(arguments: ["help", "builds"], environment: environment).exitCode == 0)
        #expect(await CumulusCLI.run(arguments: ["version"], environment: environment).stdout == "cumulus 1.0 (7)\n")
    }

    @Test func aTableAtATerminalSaysItInWords() async throws {
        let environment = try await CLIFixture.environment(isTerminal: true, pro: false)
        let result = await CumulusCLI.run(arguments: ["builds"], environment: environment)

        #expect(result.exitCode == 9)
        #expect(result.stderr.contains("Cumulus Pro is required.") && !result.stderr.contains("{"))
    }

    @Test func withoutTheAppsWordThereIsNoPro() async throws {
        let result = try await run(["apps"], pro: nil)

        #expect(result.exitCode == 9 && result.stderr.contains("PRO_REQUIRED"))
        #expect(result.stderr.contains("Open the Cumulus app, then try again."))
        #expect(try await run(["status"], pro: nil).exitCode == 0)
    }

    @Test func theAppsOwnRefusalOfALaunchIsTheSameCode() {
        let failure = CLIAppLink.failure(for: IPCResult(reason: IPCLaunchReason.proRequired, launched: false))
        #expect(failure.code == .proRequired && failure.code.exitCode == 9)
    }
}

struct ProMCPTests {
    private func items(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items)? = value { items } else { [] }
    }

    private func reply(_ json: String, pro: Bool?) async throws -> JSONValue {
        let server = MCPServer(environment: try await CLIFixture.environment(pro: pro))
        return try #require(await server.response(to: Data(json.utf8)))
    }

    @Test func theServerStartsAndListsItsToolsWithoutPro() async throws {
        let hello = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#, pro: false)
        #expect(hello["result"]?["serverInfo"]?["name"] == "cumulus")

        let list = try await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, pro: false)
        #expect(items(list["result"]?["tools"]).count == MCPTools.all.count)
    }

    @Test(arguments: [false, nil] as [Bool?])
    func everyToolAnswersThatProIsRequiredAsAResultTheModelReads(pro: Bool?) async throws {
        for tool in ["get_status", "list_builds", "list_accounts", "refresh"] {
            let reply = try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#, pro: pro)

            #expect(reply["error"] == nil, "\(tool): a refusal is not a protocol error")
            let result = try #require(reply["result"])
            #expect(result["isError"] == true && result["structuredContent"] == nil)
            let text = try #require(items(result["content"]).first?["text"]?.stringValue)
            #expect(text.contains("PRO_REQUIRED") && !text.contains("cumulus status"), "\(tool)")
        }
    }

    @Test func anUnknownToolIsStillAProtocolError() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#, pro: false)
        #expect(reply["error"] != nil)
    }
}

@MainActor
struct ProAgentLaunchTests {
    @Test func theAppRefusesALaunchWithoutProWhateverTheFileSays() async throws {
        let accounts = TestAccounts()
        try await accounts.add("Personal")
        accounts.model.pro = ProStore(source: StubProSource(), forced: .free)
        let service = AgentLaunchService(accounts: accounts.model, preferences: NotificationPreferences(defaults: accounts.defaults), notify: { _ in })

        let result = await service.launch(IPCLaunchRequest(workflowID: "w-ci", source: .branch("main"), clean: false, accountID: nil))

        #expect(result.launched == false && result.reason == IPCLaunchReason.proRequired)
    }
}
