import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

struct MCPServerTests {
    private func server(_ environment: CLIEnvironment? = nil) async throws -> MCPServer {
        let environment = if let environment { environment } else { try await CLIFixture.environment() }
        return MCPServer(environment: environment)
    }

    private func reply(_ json: String, from server: MCPServer) async throws -> JSONValue {
        try #require(await server.response(to: Data(json.utf8)))
    }

    private func call(_ name: String, _ arguments: String = "{}", on server: MCPServer) async throws -> JSONValue {
        try #require(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#, from: server)["result"])
    }

    private func errorCode(_ reply: JSONValue) -> JSONValue? {
        reply["error"]?["code"]
    }

    // MARK: - Protocol

    @Test func initializeAgreesOnAVersionAndIntroducesTheServer() async throws {
        let server = try await server()
        let reply = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#, from: server)
        let result = try #require(reply["result"])

        #expect(reply["jsonrpc"] == "2.0" && reply["id"] == 1)
        #expect(result["protocolVersion"] == "2025-11-25")
        #expect(result["capabilities"] == ["tools": ["listChanged": false]])
        #expect(result["serverInfo"] == ["name": "cumulus", "title": "Cumulus", "version": "1.0"])
        let instructions = try #require(result["instructions"]?.stringValue)
        #expect(instructions.split(separator: "\n").count <= 5)
        for phrase in ["cache", "meta.lastSuccessfulSync", "refresh", "estimates", "no tool cancels a build"] {
            #expect(instructions.contains(phrase))
        }
    }

    @Test func everyKnownVersionIsEchoedAndAnUnknownOneFallsBack() async throws {
        let server = try await server()
        for version in ["2025-03-26", "2025-06-18", "2025-11-25"] {
            let reply = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#, from: server)
            #expect(reply["result"]?["protocolVersion"] == .string(version))
        }
        let future = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2030-01-01"}}"#, from: server)
        #expect(future["result"]?["protocolVersion"] == "2025-06-18")
        let silent = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, from: server)
        #expect(silent["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test func notificationsGetNoAnswerAndPingGetsAnEmptyOne() async throws {
        let server = try await server()

        #expect(await server.response(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect(await server.response(to: Data(#"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#.utf8)) == nil)
        #expect(try await reply(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#, from: server) == ["jsonrpc": "2.0", "id": "p", "result": [:]])
    }

    @Test func theIdGoesBackAsItCame() async throws {
        let server = try await server()

        #expect(try await reply(#"{"jsonrpc":"2.0","id":42,"method":"ping"}"#, from: server)["id"] == 42)
        #expect(try await reply(#"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#, from: server)["id"] == "abc-1")
        #expect(String(decoding: try #require(await server.handle(line: Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8))), as: UTF8.self)
            == #"{"id":7,"jsonrpc":"2.0","result":{}}"#)
    }

    @Test func protocolMistakesAreJSONRPCErrors() async throws {
        let server = try await server()

        let garbage = try await reply("not json", from: server)
        #expect(errorCode(garbage) == -32700 && garbage["id"] == .null)
        #expect(errorCode(try await reply("[]", from: server)) == -32600)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":1}"#, from: server)) == -32600)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, from: server)) == -32601)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_build"}}"#, from: server)) == -32602)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, from: server)) == -32602)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_builds","arguments":[]}}"#, from: server)) == -32602)
    }

    @Test func wrongArgumentsAreInvalidParams() async throws {
        let server = try await server()
        func code(_ name: String, _ arguments: String) async throws -> JSONValue? {
            errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#, from: server))
        }

        #expect(try await code("list_builds", #"{"limit":"ten"}"#) == -32602)
        #expect(try await code("list_builds", #"{"limit":0}"#) == -32602)
        #expect(try await code("list_builds", #"{"limit":2.5}"#) == -32602)
        #expect(try await code("list_builds", #"{"failed":"yes"}"#) == -32602)
        #expect(try await code("list_builds", #"{"pull_request":0}"#) == -32602)
        #expect(try await code("list_builds", #"{"pull_request":1.5}"#) == -32602)
        #expect(try await code("list_builds", #"{"branch":"main","pull_request":12}"#) == -32602)
        #expect(try await code("list_builds", #"{"since":"yesterday"}"#) == -32602)
        #expect(try await code("list_builds", #"{"tag":"v1.0"}"#) == -32602)
        #expect(try await code("get_build", "{}") == -32602)
        #expect(try await code("get_usage", #"{"breakdown":"weekly"}"#) == -32602)
        #expect(try await code("refresh", #"{"timeoutSeconds":0}"#) == -32602)
        #expect(try await code("get_status", #"{"verbose":true}"#) == -32602)
    }

    // MARK: - Tools

    @Test func theTwelveToolsAreDescribedForAnAgent() async throws {
        let server = try await server()
        let tools = try #require(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, from: server)["result"]?["tools"])
        guard case .array(let list) = tools else {
            Issue.record("tools is not an array")
            return
        }

        #expect(list.compactMap { $0["name"]?.stringValue } == ["get_status", "list_apps", "list_builds", "get_build", "list_workflows", "get_usage", "refresh", "start_build", "get_testflight", "give_testflight_build", "expire_testflight_build", "list_accounts",
        ])
        let writers: Set<String> = ["start_build", "give_testflight_build", "expire_testflight_build"]
        for tool in list {
            #expect((tool["description"]?.stringValue?.count ?? 0) > 80)
            #expect(tool["inputSchema"]?["type"] == "object" && tool["inputSchema"]?["additionalProperties"] == false)
            let name = tool["name"]?.stringValue ?? ""
            #expect(tool["annotations"]?["destructiveHint"] == .bool(name == "expire_testflight_build"), "only an expiration cannot be undone")
            #expect(tool["annotations"]?["idempotentHint"] == .bool(!writers.contains(name)))
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(name != "refresh" && !writers.contains(name)))
        }
        let builds = list[2]["inputSchema"]
        #expect(Set(builds?["properties"]?.objectValue?.keys ?? [:].keys) == ["account", "app", "branch", "failed", "limit", "pull_request", "running", "since"])
        // Every tool that reads an account takes its name; the one that lists the accounts does not.
        #expect(list.dropLast().allSatisfy { $0["inputSchema"]?["properties"]?["account"]?["type"] == "string" })
        #expect(list[11]["inputSchema"]?["properties"] == [:])
        #expect(list[7]["inputSchema"]?["required"] == ["workflow"])
        #expect(list[8]["inputSchema"]?["required"] == ["reference"] && list[10]["inputSchema"]?["required"] == ["reference"])
        #expect(Set(list[9]["inputSchema"]?["properties"]?.objectValue?.keys ?? [:].keys) == ["account", "groups", "locale", "notes", "notify", "reference", "remove_groups"])
        #expect(list[9]["inputSchema"]?["properties"]?["groups"] == ["type": "array", "items": ["type": "string"], "description": "Names of the groups to give the build to."])
        #expect(builds?["properties"]?["limit"] == ["type": "integer", "minimum": 1, "maximum": 100, "default": 10, "description": "How many builds to return."])
        #expect(builds?["required"] == [])
        #expect(list[3]["inputSchema"]?["required"] == ["reference"])
        #expect(list[5]["inputSchema"]?["properties"]?["breakdown"]?["enum"] == ["summary", "byApp", "byWorkflow", "daily"])
        #expect(list[0]["description"]?.stringValue?.contains("not official") == true)
    }

    @Test func aToolAnswersWithTheCommandsOwnJSON() async throws {
        let environment = try await CLIFixture.environment()
        let server = try await server(environment)
        let result = try await call("list_builds", #"{"app":"alpha","failed":true,"limit":5}"#, on: server)
        let command = await CumulusCLI.run(arguments: ["builds", "--app", "alpha", "--failed", "--limit", "5", "--json"], environment: environment)

        #expect(result["isError"] == false)
        #expect(result["structuredContent"] == JSONValue(data: Data(command.stdout.utf8)))
        #expect(result["content"] == [["type": "text", "text": .string(result["structuredContent"]?.compactString ?? "")]])
        guard case .array(let builds)? = result["structuredContent"]?["data"] else { return }
        #expect(builds.compactMap { $0["reference"]?.stringValue } == ["Alpha#44", "Alpha#42"])
        #expect(result["structuredContent"]?["meta"]?["lastSuccessfulSync"] == "2026-10-10T09:55:00Z")
    }

    @Test func aToolAnswersForTheAccountItIsGiven() async throws {
        let server = try await server(try await CLIFixture.environmentWithTwoAccounts())

        guard case .array(let accounts)? = try await call("list_accounts", on: server)["structuredContent"]?["data"] else {
            Issue.record("list_accounts returned no list")
            return
        }
        #expect(accounts.compactMap { $0["name"]?.stringValue } == ["Personal", "Work"])
        #expect(accounts.map { $0["selected"] } == [true, false])

        let shown = try await call("list_apps", on: server)
        #expect(shown["structuredContent"]?["meta"]?["account"] == "Personal")
        let named = try await call("list_apps", #"{"account":"Work"}"#, on: server)
        #expect(named["structuredContent"]?["meta"]?["account"] == "Work")
        #expect(named["structuredContent"]?["data"]?.compactString.contains("Delta") == true)

        // An account that does not exist is a result the model reads, with the accounts that do.
        let missing = try await call("get_status", #"{"account":"Client"}"#, on: server)
        #expect(missing["isError"] == true && missing["content"]?.compactString.contains("Known account: Work") == true)

        // The one tool that is not about an account takes none.
        let reply = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_accounts","arguments":{"account":"Work"}}}"#, from: server)
        #expect(errorCode(reply) == -32602)
        let wrongType = try await self.reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_apps","arguments":{"account":3}}}"#, from: server)
        #expect(errorCode(wrongType) == -32602)
    }

    @Test func everyToolRuns() async throws {
        let server = try await server()

        let status = try await call("get_status", on: server)
        #expect(status["structuredContent"]?["data"]?["runningBuilds"] == 2 && status["structuredContent"]?["meta"]?["isEstimate"] == true)

        guard case .array(let apps)? = try await call("list_apps", on: server)["structuredContent"]?["data"] else { return }
        #expect(apps.count == 3)

        let build = try await call("get_build", #"{"reference":"Alpha#44"}"#, on: server)
        #expect(build["structuredContent"]?["data"]?["detailsAvailable"] == true)
        #expect(build["structuredContent"]?["data"]?["failedTests"]?.compactString.contains("testSignIn()") == true)

        guard case .array(let workflows)? = try await call("list_workflows", #"{"app":"Beta"}"#, on: server)["structuredContent"]?["data"] else { return }
        #expect(workflows.compactMap { $0["name"]?.stringValue } == ["Release"])

        let usage = try await call("get_usage", #"{"breakdown":"byWorkflow"}"#, on: server)
        #expect(usage["structuredContent"]?["data"]?["byWorkflow"] != nil && usage["structuredContent"]?["data"]?["daily"] == nil)
        #expect(try await call("get_usage", on: server)["structuredContent"]?["data"]?["summary"]?["billedMinutes"] == 15)
    }

    @Test func refreshWaitsByDefaultAndReturnsTheStatus() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        let server = try await server(environment)

        let waited = try await call("refresh", on: server)
        #expect(waited["structuredContent"]?["data"]?["accepted"] == true && waited["structuredContent"]?["data"]?["waited"] == true)
        #expect(waited["structuredContent"]?["data"]?["status"]?["appCount"] == 3)
        _ = try await call("refresh", #"{"wait":false,"timeoutSeconds":5}"#, on: server)
        #expect(await service.refreshWaits == [true, false])
        await socket.stop()
    }

    @Test func startBuildGoesThroughTheAppAndAnswersWithTheReference() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        let server = try await server(environment)

        let started = try await call("start_build", #"{"workflow":"CI","pull_request":12}"#, on: server)
        #expect(started["isError"] == false && started["structuredContent"]?["data"]?["reference"] == "Alpha#46")
        #expect(await service.launches == [IPCLaunchRequest(workflowID: "w-ci", source: .pullRequest(12), clean: false, accountID: "default")])
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_build","arguments":{}}}"#, from: server)) == -32602)
        #expect(errorCode(try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_build","arguments":{"workflow":"CI","branch":"main","tag":"v1"}}}"#, from: server)) == -32602)

        await service.set(launchResult: IPCResult(reason: IPCLaunchReason.notAllowed, launched: false))
        let refused = try await call("start_build", #"{"workflow":"CI"}"#, on: server)
        #expect(refused["isError"] == true && (refused["content"]?.compactString ?? "").contains("NOT_ALLOWED"))
        await socket.stop()
    }

    @Test func theTestFlightToolsGoThroughTheAppLikeTheCommand() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        try await TestFlightFixture.write(to: environment)
        let server = try await server(environment)

        let read = try await call("get_testflight", #"{"reference":"Alpha#43"}"#, on: server)
        #expect(read["isError"] == false && read["structuredContent"]?["data"]?["build"]?["status"] == "available")
        #expect(read["structuredContent"]?["data"]?["groups"]?.compactString.contains("\"hasBuild\":true") == true)

        let gave = try await call("give_testflight_build", #"{"reference":"Alpha#43","groups":["beta"],"remove_groups":"QA","notes":"Try it","locale":"en-US","notify":false}"#, on: server)
        #expect(gave["isError"] == false && gave["structuredContent"]?["data"]?["action"] == "give")
        #expect(await service.gives == [IPCTestFlightGiveRequest(
            testFlightBuildID: "tf-412", addGroupIDs: ["g-beta"], removeGroupIDs: ["g-qa"], notes: "Try it", locale: "en-US", notify: false, accountID: "default"
        )])

        let expired = try await call("expire_testflight_build", #"{"reference":"Alpha#43"}"#, on: server)
        #expect(expired["isError"] == false && expired["structuredContent"]?["data"]?["action"] == "expire")
        #expect(await service.expirations == [IPCTestFlightExpireRequest(testFlightBuildID: "tf-412", accountID: "default")])

        func code(_ name: String, _ arguments: String) async throws -> JSONValue? {
            errorCode(try await reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#, from: server))
        }
        #expect(try await code("give_testflight_build", #"{"reference":"Alpha#43"}"#) == -32602)
        #expect(try await code("give_testflight_build", #"{"groups":["QA"]}"#) == -32602)
        #expect(try await code("give_testflight_build", #"{"reference":"Alpha#43","groups":["QA"],"remove_groups":["qa"]}"#) == -32602)
        #expect(try await code("give_testflight_build", #"{"reference":"Alpha#43","groups":["QA"],"notes":"x"}"#) == -32602)
        #expect(try await code("give_testflight_build", #"{"reference":"Alpha#43","remove_groups":["QA"],"notify":true}"#) == -32602)
        #expect(try await code("give_testflight_build", #"{"reference":"Alpha#43","groups":[3]}"#) == -32602)
        #expect(try await code("expire_testflight_build", "{}") == -32602)
        #expect(try await code("expire_testflight_build", #"{"reference":"Alpha#43","groups":["QA"]}"#) == -32602)
        #expect(await service.gives.count == 1)
        #expect(await service.expirations.count == 1)

        await service.set(expireResult: IPCResult(reason: IPCTestFlightReason.capReached, message: "Next at 15:00.", written: false))
        let capped = try await call("expire_testflight_build", #"{"reference":"Alpha#43"}"#, on: server)
        #expect(capped["isError"] == true && capped["content"]?.compactString.contains("RATE_LIMITED") == true)
        await socket.stop()
    }

    @Test func withoutProTheTestFlightToolsAreRefusedAsResults() async throws {
        let server = try await server(try await CLIFixture.environment(pro: false))

        for (name, arguments) in [("get_testflight", #"{"reference":"Alpha#43"}"#), ("give_testflight_build", #"{"reference":"Alpha#43","groups":["QA"]}"#), ("expire_testflight_build", #"{"reference":"Alpha#43"}"#)] {
            let result = try await call(name, arguments, on: server)
            #expect(result["isError"] == true && result["content"]?.compactString.contains("PRO_REQUIRED") == true, "\(name)")
        }
    }

    @Test func whatAToolCannotAnswerIsAResultTheModelReads() async throws {
        let server = try await server()
        let missing = try await call("get_build", #"{"reference":"Alpha#999","fetchDetails":false}"#, on: server)
        let text = try #require(missing["content"]?.compactString)

        #expect(missing["isError"] == true && missing["structuredContent"] == nil)
        #expect(text.contains("NOT_FOUND") && text.contains("Alpha has no build 999 in the cache."))

        let ambiguous = try await call("list_workflows", #"{"app":"suite"}"#, on: server)
        #expect(ambiguous["isError"] == true && ambiguous["content"]?.compactString.contains("AMBIGUOUS") == true)

        let empty = try await self.server(try await CLIFixture.environment(snapshot: nil))
        let noCache = try await call("get_status", on: empty)
        #expect(noCache["isError"] == true && noCache["content"]?.compactString.contains("NO_CACHE") == true)

        let unreachable = try await call("refresh", on: server)
        #expect(unreachable["isError"] == true && unreachable["content"]?.compactString.contains("APP_UNREACHABLE") == true)
    }
}

struct MCPSessionTests {
    /// Collects what the session writes, line by line.
    private final class Output: Sendable {
        private let lines = Mutex<[String]>([])

        func append(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            lines.withLock { $0.append(text) }
        }

        var all: [String] { lines.withLock { $0 } }
    }

    private func stream(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in Data(text.utf8) {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func run(_ input: String, environment: CLIEnvironment? = nil) async throws -> [JSONValue] {
        let output = Output()
        let environment = if let environment { environment } else { try await CLIFixture.environment() }
        await MCPSession.run(server: MCPServer(environment: environment), input: stream(input)) { output.append($0) }
        #expect(output.all.allSatisfy { $0.hasSuffix("\n") && !$0.dropLast().contains("\n") })
        return output.all.compactMap { JSONValue(data: Data($0.utf8)) }
    }

    @Test func aWholeConversationRunsOverLines() async throws {
        let replies = try await run("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{}}}

        """)
        let byID = Dictionary(replies.compactMap { reply in reply["id"].map { ($0.compactString, reply) } }, uniquingKeysWith: { first, _ in first })

        #expect(replies.count == 3)
        #expect(byID["1"]?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(byID["2"]?["result"]?["tools"] != nil)
        #expect(byID["3"]?["result"]?["isError"] == false)
    }

    @Test func windowsLineEndingsBlankLinesAndAMissingLastNewlineAreFine() async throws {
        let replies = try await run("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n\n\r\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}")

        #expect(Set(replies.compactMap { $0["id"]?.compactString }) == ["1", "2"])
        #expect(replies.allSatisfy { $0["result"] == [:] })
    }

    @Test func aLineOverFourMegabytesIsRefusedAndTheNextOneIsServed() async throws {
        let huge = String(repeating: "a", count: MCPServer.maximumLineLength + 10)
        let replies = try await run(huge + "\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n")

        #expect(replies.count == 2)
        #expect(replies.contains { $0["error"]?["code"] == -32600 && $0["id"] == .null })
        #expect(replies.contains { $0["id"] == 9 && $0["result"] == [:] })
    }

    @Test func aSlowToolDoesNotHoldUpTheNextRequest() async throws {
        let service = FakeIPCService()
        await service.set(refreshResult: IPCResult(accepted: true, outcome: "succeeded"), delay: .milliseconds(400))
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        let replies = try await run("""
        {"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"refresh","arguments":{}}}
        {"jsonrpc":"2.0","id":"fast","method":"ping"}

        """, environment: environment)

        // Both are answered, the quick one first although it was asked second.
        #expect(replies.compactMap { $0["id"]?.stringValue } == ["fast", "slow"])
        #expect(replies.last?["result"]?["structuredContent"]?["data"]?["outcome"] == "succeeded")
        await socket.stop()
    }
}

struct JSONValueTests {
    @Test func jsonKeepsItsTypesBothWays() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":-3}}"#
        let value = try #require(JSONValue(data: Data(text.utf8)))

        #expect(value == ["a": [1, .double(2.5), "x", true, .null], "b": ["c": -3]])
        #expect(value.compactString == text)
        #expect(value["b"]?["c"] == -3 && value["missing"] == nil && value["a"]?["x"] == nil)
        #expect(JSONValue(data: Data("{".utf8)) == nil)
    }
}
