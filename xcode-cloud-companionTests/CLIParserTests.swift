import Foundation
import Testing
@testable import XcodeCloudCompanion

struct CLIParserTests {
    private let now = CLIFixture.now

    private func command(_ arguments: String...) throws -> CLICommand {
        try CLIParser.parse(arguments, now: now).command
    }

    private func usageError(_ arguments: String...) -> CLIFailure? {
        do {
            _ = try CLIParser.parse(arguments, now: now)
            return nil
        } catch {
            return error
        }
    }

    @Test func noArgumentAsksForHelp() throws {
        #expect(try command() == .help(topic: nil))
        #expect(try command("help") == .help(topic: nil))
        #expect(try command("--help") == .help(topic: nil))
        #expect(try command("help", "builds") == .help(topic: "builds"))
        #expect(try command("builds", "--help") == .help(topic: "builds"))
    }

    @Test func versionTakesOneOption() throws {
        #expect(try command("version") == .version(verbose: false))
        #expect(try command("version", "--verbose") == .version(verbose: true))
        #expect(usageError("version", "--loud")?.code == .usage)
    }

    @Test func anUnknownCommandIsAUsageError() {
        let error = usageError("deploy")

        #expect(error?.code == .usage)
        #expect(error?.message == "Unknown command 'deploy'.")
    }

    @Test func simpleQueriesTakeNoArgument() throws {
        #expect(try command("status") == .query(.status))
        #expect(try command("apps") == .query(.apps))
        #expect(usageError("status", "extra")?.message == "Unexpected argument 'extra'.")
    }

    @Test func buildsReadsItsFilters() throws {
        #expect(try command("builds") == .query(.builds(BuildsQuery())))
        #expect(try command("builds", "--app", "My App", "--failed", "--running", "--limit", "25", "--since", "7d") == .query(.builds(BuildsQuery(
            app: "My App", failed: true, running: true, limit: 25, since: now.addingTimeInterval(-7 * 86_400)
        ))))
        #expect(try command("builds", "--app=Alpha", "--limit=3") == .query(.builds(BuildsQuery(app: "Alpha", limit: 3))))
    }

    @Test func buildsRefusesWhatItCannotRead() {
        #expect(usageError("builds", "--limit", "0")?.code == .usage)
        #expect(usageError("builds", "--limit", "101")?.code == .usage)
        #expect(usageError("builds", "--limit", "many")?.code == .usage)
        #expect(usageError("builds", "--since", "yesterday")?.code == .usage)
        #expect(usageError("builds", "--app")?.message == "--app takes a value.")
        #expect(usageError("builds", "--bogus")?.message == "Unknown option '--bogus' for 'cumulus builds'.")
    }

    @Test func sinceReadsSpansAndDates() {
        #expect(CLISince.date("24h", now: now) == now.addingTimeInterval(-86_400))
        #expect(CLISince.date("30m", now: now) == now.addingTimeInterval(-1_800))
        #expect(CLISince.date("2026-10-01T12:00:00Z", now: now) == CLIFixture.date("2026-10-01T12:00:00Z"))
        #expect(CLISince.date("2026-10-01", now: now) == CLIFixture.date("2026-10-01T00:00:00Z"))
        #expect(CLISince.date("soon", now: now) == nil)
    }

    @Test func aBuildIsNamedByOneArgument() throws {
        #expect(try command("build", "Alpha#44") == .query(.build(reference: "Alpha#44", fetch: true)))
        #expect(try command("build", "--cached", "Alpha#44") == .query(.build(reference: "Alpha#44", fetch: false)))
        #expect(try command("open", "run-a44") == .open(reference: "run-a44"))
        #expect(usageError("build")?.code == .usage)
        #expect(usageError("build", "a", "b")?.code == .usage)
    }

    @Test func refreshMayWaitWithinALimit() throws {
        #expect(try command("refresh") == .refresh(wait: false, timeout: nil))
        #expect(try command("refresh", "--wait", "--timeout", "30") == .refresh(wait: true, timeout: 30))
        #expect(usageError("refresh", "--timeout", "0")?.code == .usage)
        #expect(usageError("refresh", "--timeout", "soon")?.code == .usage)
    }

    @Test func mcpTakesOneOption() throws {
        #expect(try command("mcp") == .mcp(verbose: false))
        #expect(try command("mcp", "--verbose") == .mcp(verbose: true))
        #expect(usageError("mcp", "--port", "80")?.code == .usage)
    }

    @Test func usageTakesOneBreakdown() throws {
        #expect(try command("usage") == .query(.usage(.summary)))
        #expect(try command("usage", "--by-app") == .query(.usage(.byApp)))
        #expect(try command("usage", "--by-workflow") == .query(.usage(.byWorkflow)))
        #expect(try command("usage", "--daily") == .query(.usage(.daily)))
        #expect(usageError("usage", "--daily", "--by-app")?.code == .usage)
    }

    @Test func theOutputFormatIsChosenOrLeftToTheTerminal() throws {
        #expect(try CLIParser.parse(["apps"], now: now).format == nil)
        #expect(try CLIParser.parse(["apps", "--json"], now: now).format == .json)
        #expect(try CLIParser.parse(["workflows", "--table", "--app", "Alpha"], now: now) == CLIInvocation(command: .query(.workflows(app: "Alpha")), format: .table))
        #expect(usageError("apps", "--json", "--table")?.code == .usage)
    }
}
