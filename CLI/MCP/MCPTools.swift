import Foundation

/// A tool of the MCP server: its public description, and how its arguments become a question for the cache.
nonisolated struct MCPTool: Sendable {
    enum Call: Equatable, Sendable {
        case query(CLIQuery)
        case refresh(wait: Bool, timeout: TimeInterval?)
    }

    struct InvalidArguments: Error, Equatable, Sendable {
        var message: String
    }

    var name: String
    var title: String
    var description: String
    var properties: [String: JSONValue] = [:]
    var required: [String] = []
    var readOnly = true
    /// Every tool that reads an account's cache takes `account`, to answer for another one than the app shows.
    var takesAccount = true
    var makeCall: @Sendable (Arguments, Date) throws(InvalidArguments) -> Call

    static let accountArgument = "account"
    private static let accountProperty: JSONValue = [
        "type": "string",
        "description": "An account's name, as list_accounts gives them, when the app follows several. Omit it for the account shown in the app.",
    ]

    /// The tool's own arguments, and `account` when it takes one.
    var allProperties: [String: JSONValue] {
        takesAccount ? properties.merging([Self.accountArgument: Self.accountProperty]) { own, _ in own } : properties
    }

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(allProperties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }

    /// Typed access to a call's arguments; a wrong type is the caller's mistake, said as such.
    struct Arguments: Sendable {
        var values: [String: JSONValue]

        func string(_ key: String) throws(InvalidArguments) -> String? {
            switch values[key] {
            case nil, .null?: return nil
            case .string(let value)?: return value
            default: throw InvalidArguments(message: "'\(key)' must be a string.")
            }
        }

        func bool(_ key: String) throws(InvalidArguments) -> Bool? {
            switch values[key] {
            case nil, .null?: return nil
            case .bool(let value)?: return value
            default: throw InvalidArguments(message: "'\(key)' must be a boolean.")
            }
        }

        func number(_ key: String) throws(InvalidArguments) -> Double? {
            switch values[key] {
            case nil, .null?: return nil
            case .int(let value)?: return Double(value)
            case .double(let value)?: return value
            default: throw InvalidArguments(message: "'\(key)' must be a number.")
            }
        }

        func checkNames(_ allowed: some Collection<String>) throws(InvalidArguments) {
            if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw InvalidArguments(message: "Unknown argument '\(unknown)'.")
            }
        }
    }

    /// The question a call asks, and the account it names, if any.
    func call(arguments: [String: JSONValue], now: Date) throws(InvalidArguments) -> (call: Call, account: String?) {
        let arguments = Arguments(values: arguments)
        try arguments.checkNames(allProperties.keys)
        let account = takesAccount ? try arguments.string(Self.accountArgument) : nil
        if let account, account.trimmingCharacters(in: .whitespaces).isEmpty {
            throw InvalidArguments(message: "'\(Self.accountArgument)' must be an account's name.")
        }
        return (try makeCall(arguments, now), account)
    }
}

nonisolated enum MCPTools {
    private static let appProperty: JSONValue = [
        "type": "string",
        "description": "An app: its name, bundle ID or product id, as list_apps gives them. Case does not matter.",
    ]

    static let all: [MCPTool] = [
        MCPTool(
            name: "get_status", title: "Xcode Cloud status",
            description: """
            Usage of the current Xcode Cloud billing cycle (minutes used, remaining, reset date, projection at the current pace) and how many builds run now. \
            Minutes Apple has not billed yet are estimates computed by Cumulus, not official figures. \
            A good first call: meta.lastSuccessfulSync tells how old the data is.
            """,
            makeCall: { _, _ in .query(.status) }
        ),
        MCPTool(
            name: "list_apps", title: "List apps",
            description: """
            The account's Xcode Cloud apps with their latest build, the builds running now and the minutes each used this cycle. \
            An app's name, bundleID or id is what the `app` argument of the other tools takes.
            """,
            makeCall: { _, _ in .query(.apps) }
        ),
        MCPTool(
            name: "list_builds", title: "List builds",
            description: """
            Recent Xcode Cloud builds, newest first: workflow, branch, tag or pull request, commit, status, duration and minutes. \
            Narrow them by app, to failed ones, to running ones, or to a period. Pass a build's `reference` (such as MyApp#42) or `id` to get_build.
            """,
            properties: [
                "app": appProperty,
                "failed": ["type": "boolean", "description": "Only builds that failed or errored."],
                "running": ["type": "boolean", "description": "Only builds pending or running. With `failed`, builds in either state."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 10, "description": "How many builds to return."],
                "since": ["type": "string", "description": "Only builds created since an ISO 8601 date, or within a span such as 7d, 24h or 30m."],
            ],
            makeCall: { arguments, now throws(MCPTool.InvalidArguments) in
                var query = BuildsQuery(
                    app: try arguments.string("app"), failed: try arguments.bool("failed") ?? false, running: try arguments.bool("running") ?? false
                )
                if let limit = try arguments.number("limit") {
                    guard limit == limit.rounded(), (1...Double(BuildsQuery.maximumLimit)).contains(limit) else {
                        throw MCPTool.InvalidArguments(message: "'limit' must be an integer from 1 to \(BuildsQuery.maximumLimit).")
                    }
                    query.limit = Int(limit)
                }
                if let since = try arguments.string("since") {
                    guard let date = CLISince.date(since, now: now) else {
                        throw MCPTool.InvalidArguments(message: "'since' must be an ISO 8601 date or a span such as 7d, 24h or 30m.")
                    }
                    query.since = date
                }
                return .query(.builds(query))
            }
        ),
        MCPTool(
            name: "get_build", title: "Get a build",
            description: """
            One build in detail: its actions, compiler errors and warnings, failed tests with their messages and devices, artifacts (names and sizes), \
            TestFlight builds and links. The tool to call to find out why a build failed. \
            When a finished build's details are not cached yet, the running Cumulus app fetches them once, which takes a few seconds.
            """,
            properties: [
                "reference": ["type": "string", "description": "The build: App#42, a build number when only one app has it, or a build run id."],
                "fetchDetails": ["type": "boolean", "default": true, "description": "False to answer from the cache only, without asking the app to fetch missing details."],
            ],
            required: ["reference"],
            makeCall: { arguments, _ throws(MCPTool.InvalidArguments) in
                guard let reference = try arguments.string("reference"), !reference.isEmpty else {
                    throw MCPTool.InvalidArguments(message: "'reference' is required.")
                }
                return .query(.build(reference: reference, fetch: try arguments.bool("fetchDetails") ?? true))
            }
        ),
        MCPTool(
            name: "list_workflows", title: "List workflows",
            description: """
            Xcode Cloud workflows with their test destinations, their last build, and how many builds and minutes each cost this cycle. \
            Useful to see which workflow uses the plan.
            """,
            properties: ["app": appProperty],
            makeCall: { arguments, _ throws(MCPTool.InvalidArguments) in .query(.workflows(app: try arguments.string("app"))) }
        ),
        MCPTool(
            name: "get_usage", title: "Usage of the cycle",
            description: """
            Minutes of the current billing cycle, in total and broken down by app, by workflow or by day (last 30 days), with the costliest build. \
            billedMinutes come from Apple's usage export when the user imported one; estimatedMinutes are computed by Cumulus and are not official.
            """,
            properties: [
                "breakdown": [
                    "type": "string", "enum": ["summary", "byApp", "byWorkflow", "daily"], "default": "summary",
                    "description": "Which breakdown to add to the summary.",
                ],
            ],
            makeCall: { arguments, _ throws(MCPTool.InvalidArguments) in
                guard let text = try arguments.string("breakdown") else { return .query(.usage(.summary)) }
                guard let breakdown = UsageBreakdown(rawValue: text) else {
                    throw MCPTool.InvalidArguments(message: "'breakdown' must be one of summary, byApp, byWorkflow, daily.")
                }
                return .query(.usage(breakdown))
            }
        ),
        MCPTool(
            name: "refresh", title: "Sync with App Store Connect",
            description: """
            Asks the Cumulus app to sync with App Store Connect now and, by default, waits for it and returns the fresh status. \
            Call it when meta.lastSuccessfulSync is too old for the question, or after a push to see the new build. \
            Starts the app when it is not running; a sync less than 30 seconds old is not repeated. It never starts, cancels or changes a build.
            """,
            properties: [
                "wait": ["type": "boolean", "default": true, "description": "False to return as soon as the sync has started."],
                "timeoutSeconds": ["type": "number", "minimum": 1, "maximum": 3600, "default": 120, "description": "How long to wait for the sync at most."],
            ],
            readOnly: false,
            makeCall: { arguments, _ throws(MCPTool.InvalidArguments) in
                let timeout = try arguments.number("timeoutSeconds")
                if let timeout, !(1...3_600).contains(timeout) {
                    throw MCPTool.InvalidArguments(message: "'timeoutSeconds' must be between 1 and 3600.")
                }
                return .refresh(wait: try arguments.bool("wait") ?? true, timeout: timeout)
            }
        ),
        MCPTool(
            name: "list_accounts", title: "List accounts",
            description: """
            The App Store Connect accounts (teams) the Cumulus app follows, with how fresh each one's data is. \
            Every other tool answers for the account marked `selected`, the one shown in the app, unless its `account` argument names another. \
            Most setups have a single account: then there is nothing to choose.
            """,
            takesAccount: false,
            makeCall: { _, _ in .query(.accounts) }
        ),
    ]

    static func tool(named name: String) -> MCPTool? {
        all.first { $0.name == name }
    }
}
