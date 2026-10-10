import Foundation

nonisolated enum CLIOutputFormat: Equatable, Sendable {
    case json
    case table
}

nonisolated enum CLICommand: Equatable, Sendable {
    case help(topic: String?)
    case version(verbose: Bool)
    case cacheInfo
    case query(CLIQuery)
    case open(reference: String)
    case refresh(wait: Bool, timeout: TimeInterval?)
    case mcp(verbose: Bool)
}

nonisolated struct CLIInvocation: Equatable, Sendable {
    var command: CLICommand
    /// Nil lets the output decide: a table on a terminal, JSON into a pipe.
    var format: CLIOutputFormat?
}

nonisolated enum CLIParser {
    /// The commands the help lists, in its order.
    static let commandNames = ["status", "apps", "builds", "build", "workflows", "usage", "refresh", "open", "mcp", "version", "help"]

    private struct Scan {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var positionals: [String] = []
    }

    static func parse(_ arguments: [String], now: Date = Date()) throws(CLIFailure) -> CLIInvocation {
        guard let name = arguments.first else { return CLIInvocation(command: .help(topic: nil)) }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "help", "-h", "--help":
            return CLIInvocation(command: .help(topic: rest.first))
        case "--version":
            return CLIInvocation(command: .version(verbose: false))
        case _ where commandNames.contains(name) || name == "_cache-info":
            break
        default:
            throw usage("Unknown command '\(name)'.", "Run 'cumulus help' to list the commands.")
        }
        if rest.contains(where: { $0 == "-h" || $0 == "--help" }) {
            return CLIInvocation(command: .help(topic: name))
        }

        let scan: Scan
        let command: CLICommand
        switch name {
        case "version":
            scan = try self.scan(rest, command: name, flags: ["--verbose"])
            command = .version(verbose: scan.flags.contains("--verbose"))
        case "_cache-info":
            scan = try self.scan(rest, command: name)
            command = .cacheInfo
        case "status":
            scan = try self.scan(rest, command: name)
            command = .query(.status)
        case "apps":
            scan = try self.scan(rest, command: name)
            command = .query(.apps)
        case "builds":
            scan = try self.scan(rest, command: name, flags: ["--failed", "--running"], values: ["--app", "--limit", "--since"])
            var query = BuildsQuery(app: scan.values["--app"], failed: scan.flags.contains("--failed"), running: scan.flags.contains("--running"))
            if let text = scan.values["--limit"] {
                guard let limit = Int(text), (1...BuildsQuery.maximumLimit).contains(limit) else {
                    throw usage("--limit takes a number from 1 to \(BuildsQuery.maximumLimit).")
                }
                query.limit = limit
            }
            if let text = scan.values["--since"] {
                guard let since = CLISince.date(text, now: now) else {
                    throw usage("--since takes an ISO 8601 date or a span such as 7d, 24h or 30m.")
                }
                query.since = since
            }
            command = .query(.builds(query))
        case "build":
            scan = try self.scan(rest, command: name, flags: ["--cached"], positionals: 1)
            guard let reference = scan.positionals.first else {
                throw usage("'cumulus build' takes a build: App#42 or a build run id.", "Run 'cumulus builds' to list recent builds.")
            }
            command = .query(.build(reference: reference, fetch: !scan.flags.contains("--cached")))
        case "workflows":
            scan = try self.scan(rest, command: name, values: ["--app"])
            command = .query(.workflows(app: scan.values["--app"]))
        case "usage":
            scan = try self.scan(rest, command: name, flags: ["--by-app", "--by-workflow", "--daily"])
            let chosen = scan.flags.intersection(["--by-app", "--by-workflow", "--daily"])
            guard chosen.count <= 1 else {
                throw usage("Choose one of --by-app, --by-workflow and --daily.")
            }
            let breakdown: UsageBreakdown = switch chosen.first {
            case "--by-app": .byApp
            case "--by-workflow": .byWorkflow
            case "--daily": .daily
            default: .summary
            }
            command = .query(.usage(breakdown))
        case "refresh":
            scan = try self.scan(rest, command: name, flags: ["--wait"], values: ["--timeout"])
            var timeout: TimeInterval?
            if let text = scan.values["--timeout"] {
                guard let seconds = TimeInterval(text), seconds > 0, seconds <= 3_600 else {
                    throw usage("--timeout takes a number of seconds, up to 3600.")
                }
                timeout = seconds
            }
            command = .refresh(wait: scan.flags.contains("--wait"), timeout: timeout)
        case "open":
            scan = try self.scan(rest, command: name, positionals: 1)
            guard let reference = scan.positionals.first else {
                throw usage("'cumulus open' takes a build: App#42 or a build run id.")
            }
            command = .open(reference: reference)
        default:
            scan = try self.scan(rest, command: name, flags: ["--verbose"])
            command = .mcp(verbose: scan.flags.contains("--verbose"))
        }

        guard !(scan.flags.contains("--json") && scan.flags.contains("--table")) else {
            throw usage("Choose one of --json and --table.")
        }
        let format: CLIOutputFormat? = scan.flags.contains("--json") ? .json : scan.flags.contains("--table") ? .table : nil
        return CLIInvocation(command: command, format: format)
    }

    private static func usage(_ message: String, _ suggestions: String...) -> CLIFailure {
        CLIFailure(code: .usage, message: message, suggestions: suggestions)
    }

    private static func scan(
        _ arguments: [String], command: String, flags: Set<String> = [], values: Set<String> = [], positionals: Int = 0
    ) throws(CLIFailure) -> Scan {
        let flags = flags.union(["--json", "--table"])
        var scan = Scan()
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard !optionsEnded, argument.hasPrefix("-"), argument != "-" else {
                scan.positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0]
            if flags.contains(name), parts.count == 1 {
                scan.flags.insert(name)
            } else if values.contains(name) {
                if parts.count == 2 {
                    scan.values[name] = parts[1]
                } else if index < arguments.count {
                    scan.values[name] = arguments[index]
                    index += 1
                } else {
                    throw usage("\(name) takes a value.", "Run 'cumulus help \(command)' for its options.")
                }
            } else {
                throw usage("Unknown option '\(name)' for 'cumulus \(command)'.", "Run 'cumulus help \(command)' for its options.")
            }
        }
        guard scan.positionals.count <= positionals else {
            throw usage("Unexpected argument '\(scan.positionals[positionals])'.", "Run 'cumulus help \(command)' for its options.")
        }
        return scan
    }
}
