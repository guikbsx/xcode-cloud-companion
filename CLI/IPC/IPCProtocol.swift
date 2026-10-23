import Foundation

// What the `cumulus` command and the app say to each other over the socket: one JSON object per line, each way.

nonisolated struct IPCRequest: Codable, Equatable, Sendable {
    struct Params: Codable, Equatable, Sendable {
        var wait: Bool?
        var buildRunID: String?
        /// The account `ping`, `refresh` and `launch` are about; the one on screen in the app when absent.
        var accountID: String?
        // `launch`: the workflow and exactly one of the three sources.
        var workflowID: String?
        var branch: String?
        var tag: String?
        var pullRequest: Int?
        var clean: Bool?
        // `testFlightGive` and `testFlightExpire`: the TestFlight build, and the groups by Apple's identifiers.
        var testFlightBuildID: String?
        var addGroupIDs: [String]?
        var removeGroupIDs: [String]?
        var notes: String?
        var locale: String?
        var notify: Bool?
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
    // `launch`
    var launched: Bool?
    var buildRunID: String?
    var buildNumber: Int?
    /// Why nothing was launched (`IPCLaunchReason`), and Apple's words when it refused.
    var message: String?
    // `testFlightLoad`, `testFlightGive`, `testFlightExpire`
    /// `testFlightGive` and `testFlightExpire`: Apple accepted a write. False for a request with nothing to change.
    var written: Bool?
    /// What `testFlightGive` did, by the names of the groups: given, taken, and already as asked.
    var addedGroups: [String]?
    var removedGroups: [String]?
    var unchangedGroups: [String]?
    /// The writes Apple accepted, as `DistributionStep` names.
    var steps: [String]?
    /// Whether the build was read back after the write, so the shared file shows it as Apple has it now.
    var refreshed: Bool?
    /// When a group was unknown or ambiguous: the names the app knows for the app.
    var names: [String]?
}

/// What `launch` asks: one workflow, one source, by name as the command knows them.
nonisolated struct IPCLaunchRequest: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case branch(String)
        case tag(String)
        case pullRequest(Int)

        var label: String {
            switch self {
            case .branch(let name), .tag(let name): name
            case .pullRequest(let number): "PR #\(number)"
            }
        }
    }

    var workflowID: String
    var source: Source
    var clean = false
    var accountID: String?

    init(workflowID: String, source: Source, clean: Bool = false, accountID: String? = nil) {
        self.workflowID = workflowID
        self.source = source
        self.clean = clean
        self.accountID = accountID
    }

    /// nil when the params name no workflow, or not exactly one source.
    init?(params: IPCRequest.Params?) {
        guard let params, let workflowID = params.workflowID else { return nil }
        let sources: [Source] = [params.branch.map(Source.branch), params.tag.map(Source.tag), params.pullRequest.map(Source.pullRequest)].compactMap(\.self)
        guard sources.count == 1, let source = sources.first else { return nil }
        if case .pullRequest(let number) = source, number <= 0 { return nil }
        self.init(workflowID: workflowID, source: source, clean: params.clean ?? false, accountID: params.accountID)
    }

    var params: IPCRequest.Params {
        var params = IPCRequest.Params(accountID: accountID, workflowID: workflowID, clean: clean ? true : nil)
        switch source {
        case .branch(let name): params.branch = name
        case .tag(let name): params.tag = name
        case .pullRequest(let number): params.pullRequest = number
        }
        return params
    }
}

/// Why `launch` started nothing, in `IPCResult.reason`.
nonisolated enum IPCLaunchReason {
    static let noCredentials = "noCredentials"
    static let unknownAccount = "unknownAccount"
    /// The key is declared read-only in the app, or Apple answered 403.
    static let notAllowed = "notAllowed"
    /// The app's own cap: so many launches by agents in the last hour.
    static let capReached = "capReached"
    static let unknownWorkflow = "unknownWorkflow"
    static let unknownReference = "unknownReference"
    /// 409 or 422: Apple's words are in `message`.
    static let refused = "refused"
    static let rateLimited = "rateLimited"
    static let failed = "failed"
    /// Apple did not confirm and the build list shows no new build.
    static let uncertain = "uncertain"
    /// Apple did not confirm and the build list could not be read: a build may have started.
    static let unknown = "unknown"
    /// The app itself says Cumulus Pro is not active, whatever the shared file claims.
    static let proRequired = "proRequired"
}

/// What `testFlightGive` asks: one TestFlight build, the groups to give it to and to take it from, by Apple's identifiers.
nonisolated struct IPCTestFlightGiveRequest: Equatable, Sendable {
    /// Apple's limit for the “What to test” text.
    static let maximumNotesLength = 4000

    var testFlightBuildID: String
    var addGroupIDs: [String]
    var removeGroupIDs: [String]
    var notes: String?
    var locale: String?
    var notify: Bool?
    var accountID: String?

    init(
        testFlightBuildID: String, addGroupIDs: [String] = [], removeGroupIDs: [String] = [], notes: String? = nil, locale: String? = nil,
        notify: Bool? = nil, accountID: String? = nil
    ) {
        self.testFlightBuildID = testFlightBuildID
        self.addGroupIDs = addGroupIDs
        self.removeGroupIDs = removeGroupIDs
        self.notes = notes
        self.locale = locale
        self.notify = notify
        self.accountID = accountID
    }

    /// nil when the params name no build, no group at all, a group twice, or notes without a language.
    init?(params: IPCRequest.Params?) {
        guard let params, let buildID = params.testFlightBuildID else { return nil }
        let add = params.addGroupIDs ?? []
        let remove = params.removeGroupIDs ?? []
        guard !(add + remove).isEmpty, Set(add + remove).count == (add + remove).count else { return nil }
        guard (params.notes == nil) == (params.locale == nil), (params.notes?.count ?? 0) <= Self.maximumNotesLength else { return nil }
        guard params.notes == nil || !add.isEmpty else { return nil }
        guard params.notify == nil || !add.isEmpty else { return nil }
        self.init(
            testFlightBuildID: buildID, addGroupIDs: add, removeGroupIDs: remove, notes: params.notes, locale: params.locale,
            notify: params.notify, accountID: params.accountID
        )
    }

    var params: IPCRequest.Params {
        IPCRequest.Params(
            accountID: accountID, testFlightBuildID: testFlightBuildID, addGroupIDs: addGroupIDs.isEmpty ? nil : addGroupIDs,
            removeGroupIDs: removeGroupIDs.isEmpty ? nil : removeGroupIDs, notes: notes, locale: locale, notify: notify
        )
    }
}

/// What `testFlightExpire` asks: one TestFlight build to make unavailable for testing, for good.
nonisolated struct IPCTestFlightExpireRequest: Equatable, Sendable {
    var testFlightBuildID: String
    var accountID: String?

    init(testFlightBuildID: String, accountID: String? = nil) {
        self.testFlightBuildID = testFlightBuildID
        self.accountID = accountID
    }

    init?(params: IPCRequest.Params?) {
        guard let params, let buildID = params.testFlightBuildID else { return nil }
        self.init(testFlightBuildID: buildID, accountID: params.accountID)
    }

    var params: IPCRequest.Params {
        IPCRequest.Params(accountID: accountID, testFlightBuildID: testFlightBuildID)
    }
}

/// Why `testFlightGive` and `testFlightExpire` wrote nothing, in `IPCResult.reason`.
nonisolated enum IPCTestFlightReason {
    static let noCredentials = "noCredentials"
    static let unknownAccount = "unknownAccount"
    /// Without Cumulus Pro the account is paused, and the app does not ask Apple anything for it.
    static let paused = "paused"
    /// The key is declared read-only in the app, or Apple answered 403.
    static let notAllowed = "notAllowed"
    /// The app's own cap: so many TestFlight writes by agents in the last hour.
    static let capReached = "capReached"
    /// The app has no such TestFlight build in what it read.
    static let unknownBuild = "unknownBuild"
    /// A group the app does not know for this app, or two with the same name; `IPCResult.names` lists the ones it knows.
    static let unknownGroup = "unknownGroup"
    /// An internal group that gets every build by itself is neither given nor taken.
    static let groupNotChoosable = "groupNotChoosable"
    /// The groups of the app could not be read.
    static let groupsUnreadable = "groupsUnreadable"
    /// The build is processing, expired, failed, or waits for an encryption answer: `message` says which.
    static let buildNotReady = "buildNotReady"
    /// 409 or 422: Apple's words are in `message`.
    static let refused = "refused"
    static let rateLimited = "rateLimited"
    static let failed = "failed"
    /// Apple did not confirm and the build read back does not settle it.
    static let uncertain = "uncertain"
    /// The app itself says Cumulus Pro is not active, whatever the shared file claims.
    static let proRequired = "proRequired"
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
    static let launch = "launch"
    static let testFlightLoad = "testFlightLoad"
    static let testFlightGive = "testFlightGive"
    static let testFlightExpire = "testFlightExpire"
}

nonisolated enum IPCRefreshReason {
    static let syncing = "syncing"
    static let recent = "recent"
    static let noCredentials = "noCredentials"
    /// The account was removed in the app since the command read the list.
    static let unknownAccount = "unknownAccount"
}

/// What the app does for the command. `launch` is the one call that writes at Apple, with the app's own `BuildLauncher`.
nonisolated protocol IPCService: Sendable {
    func ping(accountID: String?) async -> IPCResult
    func refresh(wait: Bool, accountID: String?) async -> IPCResult
    /// A build names itself alone: the app finds the account that holds it.
    func open(buildRunID: String) async -> IPCResult
    /// Fetches a finished build's issues, test results and artifacts into the shared cache, as opening its sheet does.
    func loadDetails(buildRunID: String) async -> IPCResult
    /// Starts a build, once, behind the key's access and the app's cap on launches by agents.
    func launch(_ request: IPCLaunchRequest) async -> IPCResult
    /// Reads what the shared folder lacks to talk about a build's TestFlight build: the build itself and the groups of its app.
    func testFlightLoad(buildRunID: String) async -> IPCResult
    /// Gives a TestFlight build to groups and takes it from others, behind the key's access and the app's cap on TestFlight writes.
    func testFlightGive(_ request: IPCTestFlightGiveRequest) async -> IPCResult
    /// Expires a TestFlight build, for good, behind the same two.
    func testFlightExpire(_ request: IPCTestFlightExpireRequest) async -> IPCResult
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
        if let accountID = request.params?.accountID, !Account.isValid(id: accountID) {
            return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'accountID' is not an account id."))
        }
        switch request.method {
        case IPCMethod.ping:
            return IPCResponse(id: request.id, result: await service.ping(accountID: request.params?.accountID))
        case IPCMethod.refresh:
            return IPCResponse(id: request.id, result: await service.refresh(wait: request.params?.wait ?? false, accountID: request.params?.accountID))
        case IPCMethod.open, IPCMethod.loadDetails:
            guard let buildRunID = request.params?.buildRunID, Self.isIdentifier(buildRunID) else {
                return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'\(request.method)' takes a buildRunID."))
            }
            let result = request.method == IPCMethod.open ? await service.open(buildRunID: buildRunID) : await service.loadDetails(buildRunID: buildRunID)
            return IPCResponse(id: request.id, result: result)
        case IPCMethod.launch:
            guard let launch = IPCLaunchRequest(params: request.params), Self.isIdentifier(launch.workflowID) else {
                return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'launch' takes a workflowID and exactly one of branch, tag and pullRequest."))
            }
            return IPCResponse(id: request.id, result: await service.launch(launch))
        case IPCMethod.testFlightLoad:
            guard let buildRunID = request.params?.buildRunID, Self.isIdentifier(buildRunID) else {
                return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'testFlightLoad' takes a buildRunID."))
            }
            return IPCResponse(id: request.id, result: await service.testFlightLoad(buildRunID: buildRunID))
        case IPCMethod.testFlightGive:
            guard let give = IPCTestFlightGiveRequest(params: request.params), Self.isIdentifier(give.testFlightBuildID),
                  (give.addGroupIDs + give.removeGroupIDs).allSatisfy(Self.isIdentifier), give.locale.map(Self.isIdentifier) ?? true
            else {
                return IPCResponse(
                    id: request.id,
                    error: IPCFailure(code: IPCFailure.invalidParams, message: "'testFlightGive' takes a testFlightBuildID, at least one group in addGroupIDs or removeGroupIDs, none twice, and notes only with a locale and an added group.")
                )
            }
            return IPCResponse(id: request.id, result: await service.testFlightGive(give))
        case IPCMethod.testFlightExpire:
            guard let expire = IPCTestFlightExpireRequest(params: request.params), Self.isIdentifier(expire.testFlightBuildID) else {
                return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.invalidParams, message: "'testFlightExpire' takes a testFlightBuildID."))
            }
            return IPCResponse(id: request.id, result: await service.testFlightExpire(expire))
        default:
            return IPCResponse(id: request.id, error: IPCFailure(code: IPCFailure.methodNotFound, message: "Unknown method '\(request.method)'."))
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
