import Foundation
import Testing
@testable import XcodeCloudCompanion

struct CLITableTests {
    @Test func columnsAlignAndNumbersHugTheRight() {
        var table = CLITable(headers: ["BUILD", "STATUS", "MINUTES"], rightAligned: [2])
        table.rows = [["Alpha#44", "failed", "~24m"], ["Beta#10", "succeeded", "9m"]]

        #expect(table.render(width: 80) == """
        BUILD     STATUS     MINUTES
        Alpha#44  failed        ~24m
        Beta#10   succeeded       9m

        """)
    }

    @Test func aTableNeverOverflowsTheTerminal() {
        var table = CLITable(headers: ["BUILD", "WORKFLOW", "MESSAGE"], uncut: [0])
        table.rows = [["Alpha#44", "Public archive with tests", String(repeating: "long ", count: 30)]]

        let lines = table.render(width: 60).split(separator: "\n")

        #expect(lines.allSatisfy { $0.count <= 60 })
        #expect(lines[1].hasPrefix("Alpha#44  "))
        #expect(lines[1].contains("…"))
    }

    @Test func textIsCutWithAnEllipsisAndKeptOnOneLine() {
        #expect(CLITable.fit("short", to: 10) == "short")
        #expect(CLITable.fit("a long message", to: 7) == "a long…")
        #expect(CLITable.fit("first\n\n  second", to: 20) == "first second")
    }

    @Test func figuresReadTheSameEverywhere() {
        #expect(CLIText.minutes(499.4) == "8h 19m")
        #expect(CLIText.minutes(37) == "37m")
        #expect(CLIText.minutes(61.2, estimated: true) == "~1h 01m")
        #expect(CLIText.duration(seconds: 45) == "45s")
        #expect(CLIText.duration(seconds: 750) == "12m 30s")
        #expect(CLIText.duration(seconds: 3_780) == "1h 03m")
        #expect(CLIText.date(CLIFixture.date("2026-10-09T15:04:00Z"), calendar: CLIFixture.calendar) == "2026-10-09 15:04")
        #expect(CLIText.age(since: CLIFixture.now.addingTimeInterval(-200), now: CLIFixture.now) == "3m ago")
        #expect(CLIText.timeLeft(until: CLIFixture.now.addingTimeInterval(2 * 86_400 + 4 * 3_600), now: CLIFixture.now) == "2d 4h")
        #expect(CLIText.percent(0.333) == "33%")
        #expect(CLIText.fileSize(2_400_000) == "2.4 MB")
    }

    @Test func onATerminalTheAnswerIsATable() async throws {
        let environment = try await CLIFixture.environment(isTerminal: true, width: 90)
        let result = await CumulusCLI.run(arguments: ["builds", "--app", "Alpha", "--limit", "3"], environment: environment)

        #expect(result.stdout == """
        BUILD     WORKFLOW  SOURCE            STATUS     CREATED           DURATION  MINUTES
        Alpha#45  CI        main              running    2026-10-10 09:50    9m 00s      ~0m
        Alpha#44  CI        PR #12 fix/login  failed     2026-10-09 15:00   12m 00s     ~24m
        Alpha#43  CI        main              succeeded  2026-10-08 09:00   10m 00s      15m

        ~ Estimate, not an official Apple figure.
        Last sync: 2026-10-10 09:55 (5m ago)

        """)
        #expect(await CumulusCLI.run(arguments: ["builds", "--json", "--limit", "1"], environment: environment).stdout.hasPrefix("{"))
    }

    @Test func aBuildReadsAsSections() async throws {
        let environment = try await CLIFixture.environment(isTerminal: true, width: 100)
        let text = await CumulusCLI.run(arguments: ["build", "Alpha#44"], environment: environment).stdout

        #expect(text.contains("Build       Alpha#44  failed"))
        #expect(text.contains("Source      PR #12 fix/login"))
        #expect(text.contains("Commit      01234567 Fix the login screen (Ada)"))
        #expect(text.contains("error         Cannot find 'LoginView' in scope  Sources/Login.swift:42"))
        #expect(text.contains("… and 10 more warnings"))
        #expect(text.contains("LoginTests.testSignIn()"))
        #expect(text.contains("Tests: 3 run, 1 failed, 1 skipped."))
        #expect(text.contains("Logs.zip") && text.contains("2.4 MB"))
        #expect(text.split(separator: "\n").allSatisfy { $0.count <= 100 || $0.hasPrefix("Link") })
    }

    @Test func statusReadsAsLabelledLines() async throws {
        let environment = try await CLIFixture.environment(isTerminal: true)
        let text = await CumulusCLI.run(arguments: ["status"], environment: environment).stdout

        #expect(text.contains("Cycle        2026-10-01 00:00 to 2026-11-01 00:00 (resets in 21d 14h)"))
        #expect(text.contains("Used         ~1h 15m of 25h (5%)"))
        #expect(text.contains("  Billed     15m, export imported 1d ago"))
        #expect(text.contains("Running      2 builds"))
        #expect(text.hasSuffix("~ Estimate, not an official Apple figure.\nLast sync: 2026-10-10 09:55 (5m ago)\n"))
    }
}
