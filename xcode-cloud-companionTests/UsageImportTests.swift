import Foundation
import Testing
@testable import XcodeCloudCompanion

struct UsageExportParserTests {
    @Test func appStoreConnectExportsAreRead() throws {
        let export = try UsageExportParser.parse(Fixture.csv("usage_2026-09-09_2026-10-09"), fileName: "usage_2026-09-09_2026-10-09.csv")

        #expect(export.builds.count == 6)
        #expect(export.builds.reduce(0) { $0 + $1.minutes } == 144)
        let first = try #require(export.builds.first)
        #expect(first == BilledBuild(product: "AppOne", buildNumber: 359, workflow: "Public archive (with test)", startedAt: Date(timeIntervalSince1970: 1_789_399_093), minutes: 23))
        #expect(export.builds.last?.workflow == #"Release, "nightly" build"#)
    }

    @Test func theFileNameGivesTheCoveredDaysLastDayIncluded() {
        let coverage = UsageExportParser.coverage(fileName: "usage_2026-09-09_2026-10-09.csv")

        #expect(coverage?.start == Date(timeIntervalSince1970: 1_788_912_000))
        #expect(coverage?.end == Date(timeIntervalSince1970: 1_791_590_400))
        #expect(UsageExportParser.coverage(fileName: "export.csv") == nil)
        #expect(UsageExportParser.isUsageExport(fileName: "usage_2026-09-09_2026-10-09.csv"))
        #expect(!UsageExportParser.isUsageExport(fileName: "usage_2026-09-09_2026-10-09 (1).csv.download"))
    }

    @Test func columnsAreFoundByNameAndBlankLinesIgnored() throws {
        let csv = "Workflow,Usage (Minutes),Product,Started At,Build Number\r\nDefault,4,App,2026-10-01T10:00:00Z,7\r\n\r\n"

        let export = try UsageExportParser.parse(Data(csv.utf8), fileName: "elsewhere.csv")

        #expect(export.builds == [BilledBuild(product: "App", buildNumber: 7, workflow: "Default", startedAt: Date(timeIntervalSince1970: 1_790_848_800), minutes: 4)])
        #expect(export.coverage.start == Date(timeIntervalSince1970: 1_790_848_800))
    }

    @Test func otherFilesAreRefusedWithAReason() {
        #expect(throws: UsageImportError.missingColumns(["Build Number", "Usage (Minutes)"])) {
            try UsageExportParser.parse(Data("Product,Started At,Workflow\nA,2026-10-01T10:00:00Z,W\n".utf8), fileName: "x.csv")
        }
        #expect(throws: UsageImportError.invalidRow(line: 2)) {
            try UsageExportParser.parse(Data("Build Number,Product,Started At,Usage (Minutes),Workflow\nabc,A,2026-10-01T10:00:00Z,3,W\n".utf8), fileName: "x.csv")
        }
        #expect(throws: UsageImportError.empty) {
            try UsageExportParser.parse(Data("Build Number,Product,Started At,Usage (Minutes),Workflow\n".utf8), fileName: "x.csv")
        }
    }
}

struct UsageLedgerTests {
    private func build(_ number: Int, minutes: Int, daysAgo: Double = 1) -> BilledBuild {
        BilledBuild(product: "App", buildNumber: number, workflow: "W", startedAt: Date(timeIntervalSince1970: 1_791_547_200 - daysAgo * 86_400), minutes: minutes)
    }

    @Test func aNewImportReplacesTheSameBuildsAndKeepsTheOthers() {
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        var ledger = UsageLedger()
        ledger.merge(UsageExport(builds: [build(1, minutes: 10), build(2, minutes: 20)], coverage: DateInterval(start: now, duration: 0)), fileName: "a.csv", modifiedAt: now, importedAt: now)

        ledger.merge(UsageExport(builds: [build(2, minutes: 25), build(3, minutes: 30)], coverage: DateInterval(start: now, duration: 60)), fileName: "b.csv", modifiedAt: now, importedAt: now)

        #expect(ledger.builds.values.map(\.minutes).sorted() == [10, 25, 30])
        #expect(ledger.billedBuild(product: "App", buildNumber: 2)?.minutes == 25)
        #expect(ledger.lastCoverage?.duration == 60)
        #expect(ledger.hasImported(fileName: "a.csv", modifiedAt: now))
        #expect(!ledger.hasImported(fileName: "a.csv", modifiedAt: now.addingTimeInterval(1)))
    }

    @Test func veryOldBuildsAreForgotten() {
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        var ledger = UsageLedger()

        ledger.merge(UsageExport(builds: [build(1, minutes: 10, daysAgo: 200), build(2, minutes: 5)], coverage: DateInterval(start: now, duration: 0)), fileName: "a.csv", modifiedAt: now, importedAt: now)

        #expect(ledger.builds.keys.sorted() == ["App#2"])
    }
}

@MainActor
struct UsageStoreTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exportsWaitingInTheFolderAreImportedOnceAndNewOnesPickedUp() async throws {
        let downloads = try makeDirectory()
        let ledgerFile = try makeDirectory().appending(path: "UsageLedger.json")
        try Fixture.csv("usage_2026-09-09_2026-10-09").write(to: downloads.appending(path: "usage_2026-09-09_2026-10-09.csv"))
        try Data("not an export".utf8).write(to: downloads.appending(path: "notes.csv"))
        let store = UsageStore(ledgerStore: UsageLedgerStore(fileURL: ledgerFile), watchedDirectory: downloads)

        await store.start()
        defer { store.stop() }
        #expect(store.ledger.builds.count == 6)
        #expect(store.lastImportFailed == false)

        try Data("Build Number,Product,Started At,Usage (Minutes),Workflow\n390,AppOne,2026-10-10T08:00:00Z,12,W\n".utf8)
            .write(to: downloads.appending(path: "usage_2026-10-10_2026-10-10.csv"))
        var waited = 0
        while store.ledger.builds.count < 7, waited < 40 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(store.ledger.builds.count == 7)

        let reloaded = UsageStore(ledgerStore: UsageLedgerStore(fileURL: ledgerFile), watchedDirectory: downloads)
        await reloaded.start()
        defer { reloaded.stop() }
        #expect(reloaded.ledger == store.ledger)
    }

    @Test func startingOverForgetsTheMinutesButNotTheExportsAlreadySeen() async throws {
        let downloads = try makeDirectory()
        let ledgerFile = try makeDirectory().appending(path: "UsageLedger.json")
        let export = downloads.appending(path: "usage_2026-09-09_2026-10-09.csv")
        try Fixture.csv("usage_2026-09-09_2026-10-09").write(to: export)
        let store = UsageStore(ledgerStore: UsageLedgerStore(fileURL: ledgerFile), watchedDirectory: downloads)
        await store.start()
        defer { store.stop() }
        #expect(store.ledger.builds.count == 6)

        await store.reset()
        await store.scanWatchedDirectory()

        #expect(store.ledger.builds.isEmpty)
        #expect(store.ledger.lastImport == nil)
        #expect(store.lastImportMessage == nil)
        let reloaded = UsageStore(ledgerStore: UsageLedgerStore(fileURL: ledgerFile), watchedDirectory: nil)
        await reloaded.start()
        #expect(reloaded.ledger.builds.isEmpty)

        await store.importFile(at: export)
        #expect(store.ledger.builds.count == 6)
    }

    @Test func aBrokenExportIsReportedAndLeavesTheLedgerUntouched() async throws {
        let folder = try makeDirectory()
        let url = folder.appending(path: "usage_2026-10-01_2026-10-02.csv")
        try Data("Product,Workflow\nA,B\n".utf8).write(to: url)
        let store = UsageStore(ledgerStore: UsageLedgerStore(fileURL: folder.appending(path: "ledger.json")), watchedDirectory: nil)

        await store.importFile(at: url)

        #expect(store.lastImportFailed)
        #expect(store.lastImportMessage?.contains("usage_2026-10-01_2026-10-02.csv") == true)
        #expect(store.ledger.builds.isEmpty)
    }

    @Test func failedSavesKeepTheLedgerAndAllowRetry() async throws {
        let folder = try makeDirectory()
        let export = folder.appending(path: "usage_2026-09-09_2026-10-09.csv")
        try Fixture.csv("usage_2026-09-09_2026-10-09").write(to: export)
        let ledgerFile = folder.appending(path: "ledger.json")
        let store = UsageStore(ledgerStore: UsageLedgerStore(fileURL: ledgerFile))
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)

        await store.importFile(at: export)
        #expect(store.lastImportFailed)
        #expect(store.lastImportMessage != nil)
        #expect(store.ledger.builds.isEmpty)

        try FileManager.default.removeItem(at: ledgerFile)
        await store.importFile(at: export)
        #expect(!store.lastImportFailed)
        #expect(store.ledger.builds.count == 6)

        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
        await store.reset()
        #expect(store.lastImportFailed)
        #expect(store.ledger.builds.count == 6)
    }
}
