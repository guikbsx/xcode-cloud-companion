import Foundation
import Testing
@testable import XcodeCloudCompanion

struct UsageCalibrationTests {
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    private func sample(_ number: Int, workflow: String = "Public archive", daysAgo: Double = 0, billed: Int, machine: Double, deviceWall: Double) -> CalibrationSample {
        CalibrationSample(
            product: "App", workflow: workflow, buildNumber: number, created: start.addingTimeInterval(Double(number) * 3600 - daysAgo * 86_400),
            billedMinutes: billed,
            minutes: ["machine": machine, "actionWallClock": machine * 1.2, "deviceWallClock": deviceWall]
        )
    }

    /// Ten builds billed like `MachineModel` says, then eight billed by the test action's wall clock on each device, as Apple did from #398.
    private var regimeChange: [CalibrationSample] {
        let before = (1...10).map { sample($0, billed: 28 + $0 % 2, machine: 28.5, deviceWall: Double(40 + $0 * 4)) }
        let after = (11...18).map { number in
            let wall = Double(60 + (number * 7) % 20)
            return sample(number, billed: Int((wall * 0.85).rounded()), machine: 30, deviceWall: wall)
        }
        return before + after
    }

    @Test func aWorkflowTakesTheFormulaThatForetoldItsLatestBuilds() throws {
        let stable = try #require(WorkflowRatios.choice(for: Array(regimeChange.prefix(10))))
        #expect(stable.formula == .machine)
        #expect(abs(stable.ratio - 28.0 / 28.5) < 0.01 || abs(stable.ratio - 29.0 / 28.5) < 0.01)

        let changed = try #require(WorkflowRatios.choice(for: regimeChange))
        #expect(changed.formula == .deviceWallClock)
        #expect(abs(changed.ratio - 0.85) < 0.02)
    }

    @Test func withoutHistoryOrWithEqualFormulasTheMachineModelStays() throws {
        #expect(try #require(WorkflowRatios.choice(for: [sample(1, billed: 20, machine: 10, deviceWall: 30)])).formula == .machine)
        let equal = (1...6).map { CalibrationSample(product: "App", workflow: "W", buildNumber: $0, created: start.addingTimeInterval(Double($0)), billedMinutes: 20, minutes: ["machine": 10, "actionWallClock": 10, "deviceWallClock": 10]) }
        let choice = try #require(WorkflowRatios.choice(for: equal))
        #expect(choice == WorkflowRatios.Choice(formula: .machine, ratio: 2))
        #expect(WorkflowRatios.choice(for: [sample(1, billed: 0, machine: 0.5, deviceWall: 0.5)]) == nil, "under a minute says nothing")
    }

    @Test func whatWasLearnedOutlivesTheBuildCache() {
        var ledger = UsageLedger()
        ledger.calibration.learn(regimeChange, now: start)

        let ratios = WorkflowRatios(snapshot: BuildSnapshot(), ledger: ledger, productNames: [:], now: start)

        #expect(ratios.choice(product: "App", workflow: "Public archive").formula == .deviceWallClock)
        #expect(ratios.choice(product: "App", workflow: "Never billed").formula == .machine)
    }

    @Test func theJournalKeepsThirtyRecentSamplesPerWorkflowAndNeverRewritesOne() {
        var calibration = UsageCalibration()
        let many = (1...40).map { sample($0, billed: 10, machine: 10, deviceWall: 10) }
        let old = sample(99, workflow: "Old", daysAgo: 400, billed: 5, machine: 5, deviceWall: 5)

        let added = calibration.learn(many + [old], now: start.addingTimeInterval(86_400))
        #expect(added)
        #expect(calibration.samples.count == 30)
        #expect(calibration.samples["App#11"] != nil && calibration.samples["App#10"] == nil, "the oldest go first")
        #expect(calibration.samples["App#99"] == nil, "nothing older than a year")

        var rewritten = sample(40, billed: 99, machine: 1, deviceWall: 1)
        let unchanged = !calibration.learn([rewritten], now: start.addingTimeInterval(86_400))
        #expect(unchanged)
        #expect(calibration.samples["App#40"]?.billedMinutes == 10)
        rewritten.buildNumber = 41
        let addedNewer = calibration.learn([rewritten], now: start.addingTimeInterval(86_400))
        #expect(addedNewer)
    }

    @Test func aBuildIsLearnedOnceBilledFinishedAndMeasured() throws {
        let created = start
        func run(_ number: Int, progress: CIExecutionProgress = .complete) -> CIBuildRun {
            CIBuildRun(id: "r\(number)", productID: "p", number: number, createdDate: created, startedDate: created, finishedDate: created.addingTimeInterval(1200), executionProgress: progress, completionStatus: .succeeded, startReason: nil, workflowID: nil, workflowName: "Public archive", sourceBranchOrTag: nil)
        }
        func test(_ number: Int) -> CIBuildAction {
            CIBuildAction(id: "t\(number)", buildRunID: "r\(number)", name: "Tests - iOS", actionType: .test, startedDate: created, finishedDate: created.addingTimeInterval(16 * 60), executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true)
        }
        let devices = (1...4).map { CITestDeviceRun(deviceName: "iPhone \($0)", osVersion: "27.2", testCount: 4000, totalSeconds: 66, isComplete: true) }
        let snapshot = BuildSnapshot(
            products: [CIProduct(id: "p", name: "App", productType: "APP", appID: nil, appName: nil, bundleID: nil)],
            runs: [run(1), run(2), run(3, progress: .running), run(4)],
            actionsByRunID: ["r1": [test(1)], "r2": [test(2)], "r3": [test(3)], "r4": [test(4)]],
            testDevicesByActionID: ["t1": devices, "t3": devices, "t4": devices]
        )
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(builds: [1, 2, 3].map { BilledBuild(product: "App", buildNumber: $0, workflow: "Public archive", startedAt: created, minutes: 54) }, coverage: DateInterval(start: created, duration: 86_400)),
            fileName: "usage.csv", modifiedAt: created, importedAt: created
        )

        let samples = UsageCalibration.samples(from: snapshot, ledger: ledger, productNames: ["p": "App"], model: MachineModel(snapshot: snapshot), now: created)

        #expect(samples.map(\.buildNumber) == [1], "#2 waits for its test results, #3 runs, #4 is not billed")
        let learned = try #require(samples.first)
        #expect(learned.billedMinutes == 54)
        #expect(learned.minutes(.deviceWallClock) == 64, "four devices for the whole 16-minute test action")
        #expect(learned.minutes(.actionWallClock) == 16)
        #expect(abs((learned.minutes(.machine) ?? 0) - 4 * (1.1 + 4.5)) < 0.001)
    }

    @Test func aLedgerWrittenBeforeTheJournalStillLoads() throws {
        let old = #"{"builds":{"App#1":{"product":"App","buildNumber":1,"workflow":"W","startedAt":800000000,"minutes":7}},"importedFiles":{}}"#
        let ledger = try JSONDecoder().decode(UsageLedger.self, from: Data(old.utf8))
        #expect(ledger.billedBuild(product: "App", buildNumber: 1)?.minutes == 7)
        #expect(ledger.calibration.samples.isEmpty)

        var learned = ledger
        learned.calibration.learn([sample(1, billed: 7, machine: 6, deviceWall: 9)], now: start)
        let roundTrip = try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(learned))
        #expect(roundTrip == learned)
    }

    @MainActor @Test func theUsageStoreLearnsAfterAnImportAndAfterASync() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = UsageLedgerStore(fileURL: folder.appending(path: "UsageLedger.json"))
        let store = UsageStore(ledgerStore: file, now: { self.start })
        let run = CIBuildRun(id: "r1", productID: "p", number: 1, createdDate: start, startedDate: start, finishedDate: start.addingTimeInterval(600), executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: nil, workflowName: "W", sourceBranchOrTag: nil)
        let archive = CIBuildAction(id: "a1", buildRunID: "r1", name: "Archive", actionType: .archive, startedDate: start, finishedDate: start.addingTimeInterval(600), executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true)
        let snapshot = BuildSnapshot(products: [CIProduct(id: "p", name: "App", productType: "APP", appID: nil, appName: nil, bundleID: nil)], runs: [run], actionsByRunID: ["r1": [archive]])
        let export = UsageExport(builds: [BilledBuild(product: "App", buildNumber: 1, workflow: "W", startedAt: start, minutes: 8)], coverage: DateInterval(start: start, duration: 86_400))
        let exportFile = UsageExportFile(url: folder.appending(path: "usage.csv"), modifiedAt: start)

        await store.record(export, from: exportFile)
        #expect(store.ledger.calibration.samples.isEmpty, "no builds known to the store yet")

        await store.learn(from: snapshot)
        #expect(store.ledger.calibration.samples["App#1"]?.billedMinutes == 8)
        #expect(await file.load()?.calibration == store.ledger.calibration)

        let other = UsageStore(ledgerStore: UsageLedgerStore(fileURL: folder.appending(path: "Other.json")), now: { self.start })
        other.snapshot = { snapshot }
        await other.record(export, from: exportFile)
        #expect(other.ledger.calibration.samples["App#1"] != nil, "an import learns at once when the builds are known")
    }
}
