import Foundation

// What the `cumulus` command and the app say to each other over the socket: one JSON object per line, each way.

nonisolated struct IPCRequest: Codable, Equatable, Sendable {
    struct Params: Codable, Equatable, Sendable {
        var wait: Bool?
        var buildRunID: String?
    }

    var id: String
    var method: String
    var params: Params?
}

/// One shape for every answer: a method fills the fields it has.
nonisolated struct IPCResult: Codable, Equatable, Sendable {
    var appVersion: String?
    var lastSuccessfulSync: Date?
    var isSyncing: Bool?
    var hasCredentials: Bool?
    var accepted: Bool?
    var reason: String?
    var outcome: String?
    var opened: Bool?
    var loaded: Bool?
}

nonisolated struct IPCFailure: Codable, Equatable, Sendable {
    static let parseError = "PARSE_ERROR"
    static let methodNotFound = "METHOD_NOT_FOUND"
    static let invalidParams = "INVALID_PARAMS"

    var code: String
    var message: String
}

nonisolated struct IPCResponse: Codable, Equatable, Sendable {
    var id: String?
    var result: IPCResult?
    var error: IPCFailure?
}

nonisolated enum IPCMethod {
    static let ping = "ping"
    static let refresh = "refresh"
    static let open = "open"
    static let loadDetails = "loadDetails"
}

nonisolated enum IPCRefreshReason {
    static let syncing = "syncing"
    static let recent = "recent"
    static let noCredentials = "noCredentials"
}

/// What the app does for the command. Nothing here writes anything at Apple.
nonisolated protocol IPCService: Sendable {
    func ping() async -> IPCResult
    func refresh(wait: Bool) async -> IPCResult
    func open(buildRunID: String) async -> IPCResult
    /// Fetches a finished build's issues, test results and artifacts into the shared cache, as opening its sheet does.
    func loadDetails(buildRunID: String) async -> IPCResult
}

nonisolated enum IPCCodec {
    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Turns a request line into an answer line.
nonisolated struct IPCDispatcher: Sendable {
    let service: any IPCService

    func reply(to line: Data) async -> Data {
        IPCCodec.encode(await response(to: line))
    }

    func response(to line: Data) async -> IPCResponse {
        guard let request = IPCCodec.decode(IPCRequest.self, from: line) else {
            return IPCResponse(error: IPCFailure(code: IPCFailure.parseError, message: "The request is not a JSON object with an id and a method."))
        }
        switch request.method {
        case IPCMethod.ping:
            return IPCResponse(id: request.id, result: await service.ping())
        case IPCMethod.refresh:
            return IPCResponse(id: request.id, result: await service.refresh(wait: request.params?.wait ?? false))
        case IPCMethod.open, IPCMethod.loadDetails:
            guard let buildRunID = request.params?.buildRunID, Self.isIdentifier(buildRunID) else {
                return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'\(request.method)' takes a buildRunID."))
            }
            let result = request.method == IPCMethod.open ? await service.open(buildRunID: buildRunID) : await service.loadDetails(buildRunID: buildRunID)
            return IPCResponse(id: request.id, result: result)
        default:
            return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.methodNotFound, message: "Unknown method '\(request.method)'."))
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
