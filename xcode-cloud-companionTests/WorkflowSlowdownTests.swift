import Foundation
import Testing
@testable import XcodeCloudCompanion

private let start = Date(timeIntervalSince1970: 1_791_000_000)

/// A successful build `index` hours after `start` that ran `minutes`, its actions named by `actions` (minutes each).
private func run(
    _ index: Int, minutes: Double, status: CICompletionStatus? = .succeeded, progress: CIExecutionProgress = .complete,
    workflowID: String = "w", product: String = "p1", message: String? = nil, web: String? = nil
) -> CIBuildRun {
    let created = start.addingTimeInterval(Double(index) * 3600)
    return CIBuildRun(
        id: "r\(index)", productID: product, number: 100 + index, createdDate: created, startedDate: created,
        finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil,
        executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil,
        workflowID: workflowID, workflowName: "Release", sourceBranchOrTag: "main",
        sourceCommit: message == nil && web == nil ? nil : CISourceCommit(commitSha: "a41c7e2b9d0f", message: message, authorName: nil, webURL: web.flatMap(URL.init(string:)))
    )
}

private func sample(_ index: Int, minutes: Double, actions: [String: Double] = [:]) -> WorkflowSlowdown.Sample {
    WorkflowSlowdown.Sample(id: "s\(index)", seconds: minutes * 60, actions: actions.mapValues { $0 * 60 })
}

/// `before` builds at `low`, then `after` at `high`, with a small ripple that never decides anything.
private func steps(before: Int, low: Double, after: Int, high: Double) -> [WorkflowSlowdown.Sample] {
    (0..<(before + after)).map { sample($0, minutes: ($0 < before ? low : high) + (Double($0 % 3) - 1) * 0.1) }
}

struct WorkflowSlowdownTests {
    @Test func aCleanStepIsFoundAtTheBuildThatStartsIt() throws {
        let found = try #require(WorkflowSlowdown(samples: steps(before: 20, low: 13, after: 10, high: 18)))

        #expect(found.buildID == "s20" && found.breakIndex == 20)
        #expect(found.buildsBefore == 20 && found.buildsAfter == 10)
        #expect(abs(found.medianBefore - 13 * 60) < 10 && abs(found.medianAfter - 18 * 60) < 10)
        #expect(abs(found.increase - 5.0 / 13) < 0.02)
        #expect(found.idsBefore.count == 20 && found.idsAfter.first == "s20")
    }

    @Test func rippleAroundOneLevelIsNotASlowdown() {
        let steady = (0..<30).map { sample($0, minutes: 13 + (Double($0 % 5) - 2) * 0.3) }

        #expect(WorkflowSlowdown(samples: steady) == nil)
    }

    @Test func aSingleSlowBuildIsAnOutlierNotALevel() {
        var series = steps(before: 30, low: 13, after: 0, high: 13)
        series[22] = sample(22, minutes: 40)

        #expect(WorkflowSlowdown(samples: series) == nil)
    }

    @Test func aSlowSteadyDriftIsNotTakenForAStep() {
        let drift = (0..<30).map { sample($0, minutes: 10 + Double($0) * 14 / 60) }

        #expect(drift.last!.seconds - drift.first!.seconds > 5 * 60, "the series does end up much slower")
        #expect(WorkflowSlowdown(samples: drift) == nil)
    }

    @Test func fewerThanFiveBuildsOnEitherSideGiveNothing() {
        #expect(WorkflowSlowdown(samples: steps(before: 4, low: 13, after: 4, high: 18)) == nil, "eight builds")
        #expect(WorkflowSlowdown(samples: steps(before: 26, low: 13, after: 4, high: 18)) == nil, "too recent")
        #expect(WorkflowSlowdown(samples: steps(before: 4, low: 13, after: 26, high: 18)) == nil, "too few before")
        #expect(WorkflowSlowdown(samples: []) == nil)
    }

    @Test func fiveAndFiveIsEnough() throws {
        let found = try #require(WorkflowSlowdown(samples: steps(before: 5, low: 13, after: 5, high: 18)))

        #expect(found.buildID == "s5")
        let recent = try #require(WorkflowSlowdown(samples: steps(before: 25, low: 13, after: 5, high: 18)))
        #expect(recent.buildID == "s25")
    }

    @Test func aStepNeedsFifteenPercentAndAMinute() {
        #expect(WorkflowSlowdown(samples: steps(before: 20, low: 20, after: 10, high: 22)) == nil, "10 %, two minutes")
        #expect(WorkflowSlowdown(samples: steps(before: 20, low: 2, after: 10, high: 2.6)) == nil, "30 %, 36 seconds")
        #expect(WorkflowSlowdown(samples: steps(before: 20, low: 2, after: 10, high: 3.2)) != nil, "60 %, over a minute")
    }

    @Test func aWorkflowThatGotFasterShowsNothing() {
        #expect(WorkflowSlowdown(samples: steps(before: 20, low: 18, after: 10, high: 13)) == nil)
    }

    @Test func onlyTheNewestThirtyBuildsAreLookedAt() {
        // The step is forty builds back: the thirty that count are all on the slow side.
        let old = steps(before: 5, low: 13, after: 35, high: 18)

        #expect(WorkflowSlowdown(samples: old) == nil)
        let recent = steps(before: 22, low: 13, after: 18, high: 18)
        #expect(WorkflowSlowdown(samples: recent)?.breakIndex == 12, "22 old ones fall off, 10 of them remain in the thirty")
        #expect(WorkflowSlowdown(samples: recent)?.buildID == "s22")
    }

    @Test func failedCanceledAndRunningBuildsAreIgnored() throws {
        var runs = (0..<30).map { run($0, minutes: 13) }
        runs += (0..<10).map { run(100 + $0, minutes: 45, status: .failed) }
        runs += (0..<10).map { run(200 + $0, minutes: 45, status: .canceled) }
        runs += [run(300, minutes: 45, status: nil, progress: .running)]

        #expect(WorkflowSlowdown(runs: runs, actionsByRunID: [:]) == nil)

        let slow = (0..<15).map { run($0, minutes: 13) } + (15..<25).map { run($0, minutes: 18) }
        let found = try #require(WorkflowSlowdown(runs: slow + runs.filter { $0.completionStatus != .succeeded }, actionsByRunID: [:]))
        #expect(found.buildID == "r15", "the failures neither hide the step nor move it")
    }

    @Test func theActionThatChangedTheMostLeadsAndSameNamesOnlyAreCompared() throws {
        let series = (0..<30).map { index -> WorkflowSlowdown.Sample in
            let slow = index >= 20
            var actions = ["Build - iOS": 2.0, "Archive - iOS": 5, "Test - iOS": slow ? 11 : 6]
            if slow { actions["Lint"] = 3 } else { actions["Notify"] = 1 }
            return sample(index, minutes: slow ? 18 : 13, actions: actions)
        }

        let found = try #require(WorkflowSlowdown(samples: series))

        #expect(found.actions.map(\.name) == ["Test - iOS", "Archive - iOS", "Build - iOS"], "Lint and Notify are on one side only")
        #expect(found.mainAction?.name == "Test - iOS")
        #expect(found.mainAction?.before == 360 && found.mainAction?.after == 660)
        #expect(found.actions.last?.delta == 0)
    }

    @Test func noActionIsNamedWhenNoneChangedClearly() throws {
        let series = (0..<30).map { sample($0, minutes: $0 < 20 ? 13 : 18, actions: ["Test": $0 < 20 ? 6 : 6.1]) }

        let found = try #require(WorkflowSlowdown(samples: series))

        #expect(found.mainAction == nil)
    }

    @Test func actionsAreReadFromTheSnapshotsActionsOfTheSuccessfulBuilds() throws {
        let runs = (0..<30).map { run($0, minutes: $0 < 20 ? 13 : 18) }
        var actions: [String: [CIBuildAction]] = [:]
        for (index, build) in runs.enumerated() {
            let created = build.createdDate ?? start
            actions[build.id] = [
                CIBuildAction(
                    id: "a\(index)", buildRunID: build.id, name: "Test - iOS", actionType: .test, startedDate: created,
                    finishedDate: created.addingTimeInterval(index < 20 ? 360 : 660), executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true
                ),
            ]
        }

        let found = try #require(WorkflowSlowdown(runs: runs.shuffled(), actionsByRunID: actions))

        #expect(found.buildID == "r20")
        #expect(found.mainAction?.name == "Test - iOS" && found.mainAction?.delta == 300)
    }

    @Test func aCommitLinkExistsOnlyForAKnownGitHubAddress() {
        func link(_ text: String?) -> URL? { WorkflowSlowdown.gitHubCommitURL(text.flatMap(URL.init(string:))) }

        #expect(link("https://github.com/guik/brioche/commit/a41c7e2b9d0f") != nil)
        #expect(link("http://github.com/guik/brioche/commit/a41c7e2") == nil)
        #expect(link("https://github.example.com/guik/brioche/commit/a41c7e2") == nil)
        #expect(link("https://gitlab.com/guik/brioche/-/commit/a41c7e2") == nil)
        #expect(link("https://github.com/guik/brioche/pull/12") == nil)
        #expect(link("https://github.com/guik/brioche/commit/not-a-sha") == nil)
        #expect(link(nil) == nil)
    }
}

struct WorkflowSlowdownModelTests {
    private func snapshot(_ runs: [CIBuildRun], actions: [String: [CIBuildAction]] = [:]) -> BuildSnapshot {
        BuildSnapshot(
            products: [CIProduct(id: "p1", name: "Brioche", productType: "APP", appID: nil, appName: nil, bundleID: nil)],
            runs: runs, actionsByRunID: actions, lastSuccessfulSync: start.addingTimeInterval(40 * 3600)
        )
    }

    private func slowRuns() -> [CIBuildRun] {
        (0..<30).map { index in
            run(
                index, minutes: index < 20 ? 13 : 18,
                message: index == 20 ? "Add snapshot tests\n\nBody that is not the title." : nil,
                web: index == 20 ? "https://github.com/guik/brioche/commit/a41c7e2b9d0f" : nil
            )
        }
    }

    @Test func theCardNamesTheBuildItsCommitAndItsLink() throws {
        let model = try #require(WorkflowSlowdownModel.make(
            workflowID: "w", snapshot: snapshot(slowRuns()), ledger: UsageLedger(), summary: nil, now: start.addingTimeInterval(40 * 3600)
        ))

        #expect(model.run.id == "r20" && model.buildNumber == "#120")
        #expect(model.shortSHA == "a41c7e2b" && model.commitTitle == "Add snapshot tests")
        #expect(model.commitURL?.absoluteString == "https://github.com/guik/brioche/commit/a41c7e2b9d0f")
        #expect(model.since == start.addingTimeInterval(20 * 3600))
        #expect(model.extra == nil, "no plan, no cost line")
    }

    @Test func anotherHostGivesNoLinkAndAnotherWorkflowGivesNoCard() throws {
        let runs = slowRuns().map { run in
            var copy = run
            copy.sourceCommit = CISourceCommit(commitSha: "a41c7e2b", message: nil, authorName: nil, webURL: URL(string: "https://gitlab.com/x/y/-/commit/a41c7e2b"))
            return copy
        }
        let model = try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: UsageLedger(), summary: nil, now: start))

        #expect(model.commitURL == nil && model.commitTitle == nil)
        #expect(WorkflowSlowdownModel.make(workflowID: "other", snapshot: snapshot(runs), ledger: UsageLedger(), summary: nil, now: start) == nil)
    }

    @Test func theWordsGiveTheDatesTheFiguresAndTheEstimate() throws {
        let locale = Locale(identifier: "en_US")
        let slowdown = try #require(WorkflowSlowdown(samples: steps(before: 20, low: 13, after: 10, high: 18)))
        let change = WorkflowSlowdown.ActionChange(name: "Test - iOS", before: 360, after: 660)
        let quiet = WorkflowSlowdown.ActionChange(name: "Archive", before: 300, after: 305)

        #expect(WorkflowSlowdownText.title(since: Date(timeIntervalSince1970: 1_791_547_200), locale: locale) == "Slower since October 9")
        #expect(WorkflowSlowdownText.headline(slowdown, locale: locale) == "18 min median, against 13 min before")
        #expect(WorkflowSlowdownText.increase(slowdown, locale: locale) == "+38%")
        #expect(WorkflowSlowdownText.change(change, locale: locale) == "6 min → 11 min")
        #expect(WorkflowSlowdownText.delta(change, locale: locale) == "+5 min" && WorkflowSlowdownText.delta(quiet, locale: locale) == nil)
        #expect(WorkflowSlowdownText.duration(45, locale: locale) == "45 sec")
        let extra = WorkflowSlowdownModel.Extra(perBuildMinutes: 5, cycleMinutes: 70)
        #expect(WorkflowSlowdownText.extraLine(extra, locale: locale) == "~5 min more per build, ~1 hr, 10 min over this cycle. Estimate.")
        #expect(WorkflowSlowdownText.bannerTitle(app: "Brioche", workflow: "Release", slowdown: slowdown, locale: locale) == "Brioche · Release slowed down by 38%")
    }
}

struct WorkflowSlowdownCostTests {
    private let end = start.addingTimeInterval(40 * 3600)

    private func snapshot(_ runs: [CIBuildRun]) -> BuildSnapshot {
        BuildSnapshot(
            products: [CIProduct(id: "p1", name: "Brioche", productType: "APP", appID: nil, appName: nil, bundleID: nil)],
            runs: runs, lastSuccessfulSync: end
        )
    }

    private func ledger(_ runs: [CIBuildRun], minutes: (Int) -> Int?) -> UsageLedger {
        var ledger = UsageLedger()
        for (index, run) in runs.enumerated() {
            guard let number = run.number, let billed = minutes(index) else { continue }
            ledger.builds["Brioche#\(number)"] = BilledBuild(product: "Brioche", buildNumber: number, workflow: "Release", startedAt: run.createdDate ?? start, minutes: billed)
        }
        return ledger
    }

    private func summary(measuring: Bool = false) -> UsageSummary {
        var measurement = MeasurementProgress()
        if measuring {
            measurement.totalActions = 4
            measurement.measuredActions = 1
        }
        return UsageSummary(
            plan: UsagePlan(hours: 25, resetAnchor: start), cycle: DateInterval(start: start, duration: 30 * 24 * 3600), now: end,
            billedMinutes: 0, estimatedMinutes: 0, estimatedBuildCount: 0, lastImport: end, daily: [], buildsLast30Days: 0, byApp: [], measurement: measurement
        )
    }

    private let runs = (0..<30).map { run($0, minutes: $0 < 20 ? 13 : 18) }

    @Test func theCycleCostIsTheDifferenceOfTheMediansTimesTheSlowBuildsOfTheCycle() throws {
        let billed = ledger(runs) { $0 < 20 ? 8 : 14 }

        let model = try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: billed, summary: summary(), now: end))

        #expect(model.extra == WorkflowSlowdownModel.Extra(perBuildMinutes: 6, cycleMinutes: 60))
    }

    @Test func noLineWithoutPlanDuringTheMeasureOrWhenTheCostsAreUnknownOrTheSameLevel() throws {
        let billed = ledger(runs) { $0 < 20 ? 8 : 14 }

        #expect(try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: billed, summary: nil, now: end)).extra == nil)
        #expect(try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: billed, summary: summary(measuring: true), now: end)).extra == nil)
        let few = ledger(runs) { $0 >= 20 ? 14 : ($0 < 2 ? 8 : nil) }
        #expect(try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: few, summary: summary(), now: end)).extra == nil, "two billed builds before the break")
        let same = ledger(runs) { _ in 9 }
        #expect(try #require(WorkflowSlowdownModel.make(workflowID: "w", snapshot: snapshot(runs), ledger: same, summary: summary(), now: end)).extra == nil, "the minutes did not change")
    }
}
