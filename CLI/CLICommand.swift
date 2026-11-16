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
    case launch(LaunchCommand)
    case testFlightGive(TestFlightGiveCommand)
    case testFlightExpire(TestFlightExpireCommand)
    case mcp(verbose: Bool)
}

/// `cumulus run`: a workflow by name and at most one source; without one, the branch of the workflow's last build.
nonisolated struct LaunchCommand: Equatable, Sendable {
    var workflow: String
    var branch: String?
    var tag: String?
    var pullRequest: Int?
    var clean = false
    /// `--yes`: no question at the terminal. In a pipe or over MCP there is nobody to ask: the agent decided.
    var yes = false
}

/// `cumulus testflight give`: groups to give a build's TestFlight build to and to take it from, by name (or Apple's identifier).
nonisolated struct TestFlightGiveCommand: Equatable, Sendable {
    var build: String
    var add: [String] = []
    var remove: [String] = []
    var notes: String?
    var locale: String?
    /// nil leaves the build's setting as it is.
    var notify: Bool?
    /// `--yes`: no question at the terminal. In a pipe or over MCP there is nobody to ask: the agent decided.
    var yes = false
}

/// `cumulus testflight expire`: makes the build's TestFlight build unavailable for testing, for good.
nonisolated struct TestFlightExpireCommand: Equatable, Sendable {
    var build: String
    var yes = false
}

nonisolated struct CLIInvocation: Equatable, Sendable {
    var command: CLICommand
    /// Nil lets the output decide: a table on a terminal, JSON into a pipe.
    var format: CLIOutputFormat?
    /// `--account`: the account to answer for, by name; nil for the one on screen in the app.
    var account: String?
}

nonisolated enum CLIParser {
    /// The commands the help lists, in its order.
    static let commandNames = ["status", "accounts", "apps", "builds", "build", "workflows", "usage", "refresh", "run", "testflight", "open", "mcp", "version", "help"]

    private struct Scan {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        /// The options that may be repeated, in the order given.
        var lists: [String: [String]] = [:]
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
            scan = try self.scan(rest, command: name, flags: ["--verbose"], takesAccount: false)
            command = .version(verbose: scan.flags.contains("--verbose"))
        case "_cache-info":
            scan = try self.scan(rest, command: name)
            command = .cacheInfo
        case "accounts":
            scan = try self.scan(rest, command: name, takesAccount: false)
            command = .query(.accounts)
        case "status":
            scan = try self.scan(rest, command: name)
            command = .query(.status)
        case "apps":
            scan = try self.scan(rest, command: name)
            command = .query(.apps)
        case "builds":
            scan = try self.scan(rest, command: name, flags: ["--failed", "--running"], values: ["--app", "--limit", "--since", "--branch", "--pr"])
            var query = BuildsQuery(app: scan.values["--app"], failed: scan.flags.contains("--failed"), running: scan.flags.contains("--running"))
            if let branch = scan.values["--branch"] {
                guard scan.values["--pr"] == nil else { throw usage("Choose --branch or --pr, not both.") }
                query.branch = branch
            }
            if let text = scan.values["--pr"] {
                guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text), number > 0 else {
                    throw usage("--pr takes a pull request number, such as 128 or #128.")
                }
                query.pullRequest = number
            }
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
        case "run":
            scan = try self.scan(rest, command: name, flags: ["--clean", "--yes"], values: ["--branch", "--tag", "--pr"], positionals: 1)
            guard let workflow = scan.positionals.first?.trimmingCharacters(in: .whitespaces), !workflow.isEmpty else {
                throw usage("'cumulus run' takes a workflow: its name, or App/Workflow.", "Run 'cumulus workflows' to list them.")
            }
            let sources = ["--branch", "--tag", "--pr"].filter { scan.values[$0] != nil }
            guard sources.count <= 1 else { throw usage("Choose one of --branch, --tag and --pr.") }
            var launch = LaunchCommand(workflow: workflow, branch: scan.values["--branch"], tag: scan.values["--tag"], clean: scan.flags.contains("--clean"), yes: scan.flags.contains("--yes"))
            if let text = scan.values["--pr"] {
                guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text), number > 0 else {
                    throw usage("--pr takes a pull request number, such as 128 or #128.")
                }
                launch.pullRequest = number
            }
            command = .launch(launch)
        case "testflight":
            switch rest.first {
            case "give":
                scan = try self.scan(
                    Array(rest.dropFirst()), command: name, flags: ["--notify", "--no-notify", "--yes"], values: ["--notes", "--locale"],
                    lists: ["--group", "--remove"], positionals: 1
                )
                command = .testFlightGive(try testFlightGive(scan))
            case "expire":
                scan = try self.scan(Array(rest.dropFirst()), command: name, flags: ["--yes"], positionals: 1)
                guard let build = scan.positionals.first else {
                    throw usage("'cumulus testflight expire' takes a build: App#42 or a build run id.", "Run 'cumulus builds' to list recent builds.")
                }
                command = .testFlightExpire(TestFlightExpireCommand(build: build, yes: scan.flags.contains("--yes")))
            default:
                scan = try self.scan(rest, command: name, flags: ["--cached"], positionals: 1)
                guard let reference = scan.positionals.first else {
                    throw usage("'cumulus testflight' takes a build: App#42 or a build run id.", "Run 'cumulus builds' to list recent builds.")
                }
                command = .query(.testFlight(reference: reference, fetch: !scan.flags.contains("--cached")))
            }
        case "open":
            scan = try self.scan(rest, command: name, positionals: 1)
            guard let reference = scan.positionals.first else {
                throw usage("'cumulus open' takes a build: App#42 or a build run id.")
            }
            command = .open(reference: reference)
        default:
            scan = try self.scan(rest, command: name, flags: ["--verbose"], takesAccount: false)
            command = .mcp(verbose: scan.flags.contains("--verbose"))
        }

        guard !(scan.flags.contains("--json") && scan.flags.contains("--table")) else {
            throw usage("Choose one of --json and --table.")
        }
        let format: CLIOutputFormat? = scan.flags.contains("--json") ? .json : scan.flags.contains("--table") ? .table : nil
        if let account = scan.values["--account"], account.trimmingCharacters(in: .whitespaces).isEmpty {
            throw usage("--account takes an account's name.", "Run 'cumulus accounts' to list the accounts.")
        }
        return CLIInvocation(command: command, format: format, account: scan.values["--account"])
    }

    private static func testFlightGive(_ scan: Scan) throws(CLIFailure) -> TestFlightGiveCommand {
        guard let build = scan.positionals.first else {
            throw usage("'cumulus testflight give' takes a build: App#42 or a build run id.", "Run 'cumulus builds' to list recent builds.")
        }
        let add = scan.lists["--group"] ?? []
        let remove = scan.lists["--remove"] ?? []
        guard !(add + remove).isEmpty else {
            throw usage("Name at least one group: --group <name> to give the build to it, --remove <name> to take it from it.", "Run 'cumulus testflight \(build)' to list the groups.")
        }
        guard (add + remove).allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw usage("--group and --remove take a group's name.")
        }
        let folded = (add + remove).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard Set(folded).count == folded.count else {
            throw usage("A group is named twice: give the build to a group or take it from it, not both.")
        }
        var command = TestFlightGiveCommand(build: build, add: add, remove: remove, yes: scan.flags.contains("--yes"))
        let wantsNotes = scan.values["--notes"] != nil || scan.values["--locale"] != nil
        if wantsNotes {
            guard let notes = scan.values["--notes"]?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty, let locale = scan.values["--locale"],
                  !locale.isEmpty, locale.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else {
                throw usage("--notes and --locale go together: --notes <text> --locale <fr-FR>.")
            }
            guard notes.count <= IPCTestFlightGiveRequest.maximumNotesLength else {
                throw usage("--notes takes at most \(IPCTestFlightGiveRequest.maximumNotesLength) characters.")
            }
            command.notes = notes
            command.locale = locale
        }
        guard !(scan.flags.contains("--notify") && scan.flags.contains("--no-notify")) else {
            throw usage("Choose one of --notify and --no-notify.")
        }
        if scan.flags.contains("--notify") { command.notify = true }
        if scan.flags.contains("--no-notify") { command.notify = false }
        guard !add.isEmpty || (command.notes == nil && command.notify == nil) else {
            throw usage("--notes, --notify and --no-notify go with --group: they apply when the build is given to a group.")
        }
        return command
    }

    private static func usage(_ message: String, _ suggestions: String...) -> CLIFailure {
        CLIFailure(code: .usage, message: message, suggestions: suggestions)
    }

    private static func scan(
        _ arguments: [String], command: String, flags: Set<String> = [], values: Set<String> = [], lists: Set<String> = [], positionals: Int = 0,
        takesAccount: Bool = true
    ) throws(CLIFailure) -> Scan {
        let flags = flags.union(["--json", "--table"])
        // Every command that reads an account's cache answers for the one on screen unless another is named.
        let values = (takesAccount ? values.union(["--account"]) : values).union(lists)
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
                let value: String
                if parts.count == 2 {
                    value = parts[1]
                } else if index < arguments.count {
                    value = arguments[index]
                    index += 1
                } else {
                    throw usage("\(name) takes a value.", "Run 'cumulus help \(command)' for its options.")
                }
                if lists.contains(name) {
                    scan.lists[name, default: []].append(value)
                } else {
                    scan.values[name] = value
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
