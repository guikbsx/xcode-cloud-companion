import Foundation

nonisolated enum CLIHelp {
    private struct Topic {
        var name: String
        var summary: String
        var usage: String
        var options: [(String, String)] = []
        var example: String
        var notes: [String] = []
    }

    private static let topics: [Topic] = [
        Topic(
            name: "status", summary: "Usage of the billing cycle and builds running now", usage: "cumulus status",
            example: "cumulus status --json",
            notes: ["Minutes Apple has not billed yet are estimated from the builds' actions."]
        ),
        Topic(
            name: "accounts", summary: "App Store Connect accounts the app follows", usage: "cumulus accounts",
            example: "cumulus accounts",
            notes: ["Every other command answers for the account shown in the app, or for the one named with --account."]
        ),
        Topic(name: "apps", summary: "Apps of the account with their latest build", usage: "cumulus apps", example: "cumulus apps"),
        Topic(
            name: "builds", summary: "Recent builds, newest first", usage: "cumulus builds [options]",
            options: [
                ("--app <app>", "Only this app: its name, bundle ID or product id"),
                ("--failed", "Only builds that failed or errored"),
                ("--running", "Only builds pending or running"),
                ("--limit <n>", "How many builds, 1 to 100 (default 10)"),
                ("--since <when>", "Created since an ISO 8601 date, or a span: 7d, 24h, 30m"),
            ],
            example: "cumulus builds --app MyApp --failed --since 7d"
        ),
        Topic(
            name: "build", summary: "One build in detail: actions, issues, failed tests", usage: "cumulus build <build> [--cached]",
            options: [("--cached", "Only what the cache holds: never ask the app to fetch the build's issues and tests")],
            example: "cumulus build MyApp#42",
            notes: [
                "<build> is App#42, a build number when only one app has it, or a build run id.",
                "Issues, tests and artifacts of a finished build are fetched once by the running app, then kept.",
            ]
        ),
        Topic(
            name: "workflows", summary: "Workflows and what they cost over the cycle", usage: "cumulus workflows [--app <app>]",
            options: [("--app <app>", "Only this app: its name, bundle ID or product id")],
            example: "cumulus workflows --app MyApp"
        ),
        Topic(
            name: "usage", summary: "Minutes of the cycle by app, by workflow or by day", usage: "cumulus usage [--by-app | --by-workflow | --daily]",
            options: [
                ("--by-app", "Minutes of the cycle for each app"),
                ("--by-workflow", "Minutes, builds and average for each workflow"),
                ("--daily", "Minutes of each of the last 30 days"),
            ],
            example: "cumulus usage --by-workflow"
        ),
        Topic(
            name: "refresh", summary: "Ask the Cumulus app for a fresh sync", usage: "cumulus refresh [--wait] [--timeout <seconds>]",
            options: [
                ("--wait", "Wait for the sync to end, then print the status"),
                ("--timeout <seconds>", "How long to wait at most (default 120)"),
            ],
            example: "cumulus refresh --wait",
            notes: ["Starts Cumulus when it is not running. A sync less than 30 seconds old is not asked again."]
        ),
        Topic(name: "open", summary: "Open a build in the Cumulus app", usage: "cumulus open <build>", example: "cumulus open MyApp#42"),
        Topic(
            name: "mcp", summary: "Serve these commands to AI agents over MCP (stdio)", usage: "cumulus mcp [--verbose]",
            options: [("--verbose", "Log each message to standard error")],
            example: "claude mcp add --scope user cumulus -- /Applications/Cumulus.app/Contents/Helpers/cumulus mcp",
            notes: ["A Model Context Protocol server over standard input and output: an agent starts it, a person rarely does."]
        ),
        Topic(
            name: "version", summary: "Version of this command", usage: "cumulus version [--verbose]",
            options: [("--verbose", "Also where the cache is and what it holds")], example: "cumulus version"
        ),
        Topic(name: "help", summary: "This list, or one command's options", usage: "cumulus help [command]", example: "cumulus help builds"),
    ]

    /// The commands that read one account's cache: each answers for another account when asked.
    private static let accountCommands: Set<String> = ["status", "apps", "builds", "build", "workflows", "usage", "refresh", "open"]
    private static let accountOption = ("--account <name>", "Answer for this account instead of the one shown in the app")

    static var overview: String {
        var lines = [
            "cumulus: Xcode Cloud builds and usage, read from the Cumulus app.",
            "",
            "USAGE: cumulus <command> [options]",
            "",
            "COMMANDS:",
        ]
        for topic in topics {
            lines.append("  \(topic.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(topic.summary)")
        }
        lines += [
            "",
            "OUTPUT:",
            "  --json     JSON: { \"data\": ..., \"meta\": { \"lastSuccessfulSync\": ... } }. The default into a pipe.",
            "  --table    Readable text. The default on a terminal.",
            "",
            "ACCOUNT:",
            "  --account <name>   Answer for this account instead of the one shown in the app ('cumulus accounts' lists them).",
            "",
            "Everything is read from the cache the Cumulus app keeps: nothing is asked from Apple.",
            "Run 'cumulus help <command>' for a command's options.",
            "Install this command and its agent skill from Cumulus › Settings › Agents.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nil for a name that is not a command.
    static func topic(_ name: String) -> String? {
        guard let topic = topics.first(where: { $0.name == name }) else { return nil }
        var lines = ["\(topic.summary).", "", "USAGE: \(topic.usage)"]
        let options = topic.options + (accountCommands.contains(name) ? [accountOption] : [])
        if !options.isEmpty {
            lines += ["", "OPTIONS:"]
            let width = options.map(\.0.count).max() ?? 0
            lines += options.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
        }
        lines += ["", "EXAMPLE:", "  \(topic.example)"]
        if !topic.notes.isEmpty {
            lines += [""] + topic.notes
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
