import Foundation
import Testing
@testable import XcodeCloudCompanion

/// The app and the `cumulus` command write the same percentage of the plan for the same minutes.
@MainActor
struct PlanShareTests {
    private let english = Locale(identifier: "en_US")

    /// 13 h 37 min of 25 h is 54.47 %: the command once rounded the fraction to 0.545 first, then wrote 55 %.
    @Test func theAppAndTheCommandWriteTheSamePercentage() async throws {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(
                builds: [BilledBuild(product: "Alpha", buildNumber: 43, workflow: "CI", startedAt: CLIFixture.date("2026-10-08T09:01:00Z"), minutes: 817)],
                coverage: DateInterval(start: CLIFixture.date("2026-10-01T00:00:00Z"), end: CLIFixture.date("2026-10-09T00:00:00Z"))
            ),
            fileName: "usage.csv", modifiedAt: CLIFixture.date("2026-10-09T07:00:00Z"), importedAt: CLIFixture.date("2026-10-09T07:00:00Z")
        )
        let snapshot = BuildSnapshot(products: CLIFixture.products, lastSuccessfulSync: CLIFixture.date("2026-10-10T09:55:00Z"))
        let environment = try await CLIFixture.environment(snapshot: snapshot, isTerminal: true)
        let directory = CLIAccountScope.directory(of: CLIFixture.account, in: environment.directory)
        try await UsageLedgerStore(fileURL: directory.appending(path: "UsageLedger.json")).save(ledger)

        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: CLIFixture.plan, now: CLIFixture.now)
        let text = await CumulusCLI.run(arguments: ["status"], environment: environment).stdout

        #expect(summary.usedMinutes == 817)
        #expect(UsageFormat.compactPercent(summary.writtenFractionUsed, locale: english) == "54%")
        #expect(StatusMenuBuilder.buttonTitle(for: summary).filter(\.isNumber) == "54")
        #expect(text.contains("of 25h (54%)"), "\(text)")
    }

    @Test func noAmountOfMinutesMakesThemDisagree() {
        let quota = 1500.0
        for step in 0...30_000 {
            let used = Double(step) * 0.0731
            let inTheApp = UsageFormat.compactPercent(CLINumber.wholePercentFraction(usedMinutes: used, quotaMinutes: quota), locale: english)
            let inTheCommand = CLIText.percent(
                CLINumber.wholePercentFraction(usedMinutes: CLINumber.minutes(used), quotaMinutes: CLINumber.minutes(quota))
            )
            guard inTheApp == inTheCommand else {
                Issue.record("\(used) min: \(inTheApp) in the app, \(inTheCommand) in the command")
                return
            }
        }
    }

    @Test func aHalfPercentRoundsUpAndAPlanWithoutMinutesIsNotUsed() {
        #expect(CLINumber.wholePercentFraction(usedMinutes: 817.5, quotaMinutes: 1500) == 0.55)
        #expect(CLINumber.wholePercentFraction(usedMinutes: 817, quotaMinutes: 1500) == 0.54)
        #expect(CLINumber.wholePercentFraction(usedMinutes: 2000, quotaMinutes: 1500) == 1.33)
        #expect(CLINumber.wholePercentFraction(usedMinutes: 10, quotaMinutes: 0) == 0)
    }

    @Test func theCycleCardWritesItsHoursOneWay() {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(
                builds: [BilledBuild(product: "Alpha", buildNumber: 43, workflow: "CI", startedAt: CLIFixture.date("2026-10-08T09:01:00Z"), minutes: 817)],
                coverage: DateInterval(start: CLIFixture.date("2026-10-01T00:00:00Z"), end: CLIFixture.date("2026-10-09T00:00:00Z"))
            ),
            fileName: "usage.csv", modifiedAt: CLIFixture.date("2026-10-09T07:00:00Z"), importedAt: CLIFixture.date("2026-10-09T07:00:00Z")
        )
        let summary = UsageCalculator.summary(snapshot: BuildSnapshot(products: CLIFixture.products), ledger: ledger, plan: CLIFixture.plan, now: CLIFixture.now)

        // The scheme runs the tests in English.
        #expect(CycleCard.Content(summary: summary)?.usedText == "13 hr, 37 min of 25 hr")
    }
}
