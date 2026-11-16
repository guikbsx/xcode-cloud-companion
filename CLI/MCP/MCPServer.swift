import Foundation

/// The Model Context Protocol over JSON-RPC 2.0, as far as a server of tools needs it: initialize, ping, tools/list, tools/call.
nonisolated struct MCPServer: Sendable {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let fallbackVersion = "2025-06-18"
    static let maximumLineLength = 4 * 1024 * 1024

    static let instructions = """
    Cumulus answers about Xcode Cloud builds and usage from the cache kept by the Cumulus macOS app; it does not call Apple itself. \
    A result is about the App Store Connect account named in meta.account: the one shown in the app, unless `account` names another (list_accounts).
    Every result carries meta.lastSuccessfulSync (how old the data is) and meta.appRunning; call `refresh` when it may be stale.
    Minutes are estimates computed by Cumulus, not official Apple figures, except fields named billed.
    Start with get_status or list_builds, then get_build with a reference such as MyApp#42 to see why a build failed.
    Only start_build, give_testflight_build and expire_testflight_build write anything, and only when the user asked; no tool cancels a build.
    """

    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    let environment: CLIEnvironment

    /// The line that answers `line`, or nil when it was a notification and nothing is owed.
    func handle(line: Data) async -> Data? {
        await response(to: line)?.compactData
    }

    func response(to line: Data) async -> JSONValue? {
        guard let message = JSONValue(data: line) else {
            return Self.failure(id: .null, code: ErrorCode.parseError, message: "Parse error: the line is not JSON.")
        }
        guard let object = message.objectValue else {
            return Self.failure(id: .null, code: ErrorCode.invalidRequest, message: "A request is one JSON object; batches are not supported.")
        }
        // No id: a notification, which never gets an answer, whatever it says.
        guard let id = object["id"] else { return nil }
        guard let method = object["method"]?.stringValue else {
            return Self.failure(id: id, code: ErrorCode.invalidRequest, message: "The request has no method.")
        }
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            if let client = params["clientInfo"]?["name"]?.stringValue {
                AgentConnectionsStore(directory: environment.directory).note(client: client, at: environment.now())
            }
            return Self.success(id: id, [
                "protocolVersion": .string(requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.fallbackVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cumulus", "title": "Cumulus", "version": .string(environment.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.success(id: id, [:])
        case "tools/list":
            return Self.success(id: id, ["tools": .array(MCPTools.all.map(\.definition))])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return Self.failure(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method).")
        }
    }

    private func callTool(id: JSONValue, params: [String: JSONValue]) async -> JSONValue {
        guard let name = params["name"]?.stringValue, let tool = MCPTools.tool(named: name) else {
            return Self.failure(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(params["name"]?.stringValue ?? "").")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default: return Self.failure(id: id, code: ErrorCode.invalidParams, message: "'arguments' must be an object.")
        }
        let call: MCPTool.Call
        let account: String?
        do {
            (call, account) = try tool.call(arguments: arguments, now: environment.now())
        } catch {
            return Self.failure(id: id, code: ErrorCode.invalidParams, message: error.message)
        }
        let runner = CLIQueryRunner(environment: environment, account: account)
        do throws(CLIFailure) {
            let response = switch call {
            case .query(let query): try await runner.run(query)
            case .refresh(let wait, let timeout): try await runner.refresh(wait: wait, timeout: timeout)
            case .launch(let command): try await runner.launch(runner.prepareLaunch(command))
            case .testFlightGive(let command): try await runner.testFlightGive(runner.prepareTestFlightGive(command))
            case .testFlightExpire(let command): try await runner.testFlightExpire(runner.prepareTestFlightExpire(command))
            }
            let structured = JSONValue(data: response.jsonData) ?? .null
            return Self.success(id: id, [
                "content": [["type": "text", "text": .string(structured.compactString)]],
                "structuredContent": structured,
                "isError": false,
            ])
        } catch {
            return Self.refusal(id: id, error)
        }
    }

    /// What the tool could not answer is a result the model reads, not a protocol error.
    private static func refusal(id: JSONValue, _ failure: CLIFailure) -> JSONValue {
        let payload = JSONValue(data: CLIJSON.data(["error": failure])) ?? .null
        return success(id: id, ["content": [["type": "text", "text": .string(payload.compactString)]], "isError": true])
    }

    static func success(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

/// Runs the server over a stream of bytes: one JSON-RPC message per line in, one per line out.
nonisolated enum MCPSession {
    /// Each request is answered in its own task, so a slow tool never holds up the reading of the next line.
    static func run<Bytes: AsyncSequence & Sendable>(
        server: MCPServer, input: Bytes, log: @escaping @Sendable (String) -> Void = { _ in }, write: @escaping @Sendable (Data) async -> Void
    ) async where Bytes.Element == UInt8 {
        await withTaskGroup(of: Void.self) { group in
            var line: [UInt8] = []
            var isOverflowing = false
            func dispatch(_ bytes: [UInt8], overflowed: Bool) {
                if overflowed {
                    group.addTask {
                        let refusal = MCPServer.failure(id: .null, code: MCPServer.ErrorCode.invalidRequest, message: "The request is larger than 4 MB.")
                        await write(refusal.compactData + Data([0x0A]))
                    }
                    return
                }
                let data = Data(bytes.last == 0x0D ? bytes.dropLast() : bytes[...])
                guard !data.isEmpty else { return }
                group.addTask {
                    log("< \(String(decoding: data.prefix(200), as: UTF8.self))")
                    guard let reply = await server.handle(line: data) else { return }
                    log("> \(String(decoding: reply.prefix(200), as: UTF8.self))")
                    await write(reply + Data([0x0A]))
                }
            }
            do {
                for try await byte in input {
                    if byte == 0x0A {
                        dispatch(line, overflowed: isOverflowing)
                        line.removeAll(keepingCapacity: true)
                        isOverflowing = false
                    } else if !isOverflowing {
                        line.append(byte)
                        if line.count > MCPServer.maximumLineLength {
                            isOverflowing = true
                            line.removeAll()
                        }
                    }
                }
            } catch {
                log("input closed: \(error)")
            }
            if !line.isEmpty, !isOverflowing {
                dispatch(line, overflowed: false)
            }
            await group.waitForAll()
        }
    }

    /// The command's own input and output. Ends when the client closes the input or sends SIGTERM, with exit code 0 either way.
    static func runOnStandardIO(environment: CLIEnvironment, verbose: Bool) async {
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { exit(0) }
        termination.resume()
        defer { termination.cancel() }

        let output = MCPOutput()
        await run(
            server: MCPServer(environment: environment),
            input: FileHandle.standardInput.bytes,
            log: { message in
                if verbose { FileHandle.standardError.write(Data("[cumulus mcp] \(message)\n".utf8)) }
            },
            write: { await output.write($0) }
        )
    }
}

/// One writer at a time: answers written by concurrent tasks never interleave.
actor MCPOutput {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }
}
