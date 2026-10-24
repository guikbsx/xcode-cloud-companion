import CoreGraphics
import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct RunningBlockTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")

    private func products() -> [CIProduct] {
        ["Sextant", "Hyrox", "Cumulus", "Delta", "Echo"].enumerated().map { index, name in
            CIProduct(id: "p\(index)", name: name, productType: "APP", appID: "\(index)", appName: nil, bundleID: nil)
        }
    }

    /// Three succeeded builds of `workflow`, each `minutes` long, so a running build of it has an estimate.
    private func history(_ workflow: String, product: String, minutes: Double) -> [CIBuildRun] {
        (1...3).map { index in
            let begin = now.addingTimeInterval(-86_400 * Double(index))
            return CIBuildRun(
                id: "\(workflow)-h\(index)", productID: product, number: index, createdDate: begin, startedDate: begin,
                finishedDate: begin.addingTimeInterval(minutes * 60), executionProgress: .complete, completionStatus: .succeeded,
                startReason: nil, workflowID: workflow, workflowName: "Release", sourceBranchOrTag: "main"
            )
        }
    }

    private func running(
        _ id: String, product: String, workflow: String, startedMinutesAgo: Double?, pending: Bool = false, number: Int = 10
    ) -> CIBuildRun {
        let started = startedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        return CIBuildRun(
            id: id, productID: product, number: number, createdDate: started ?? now.addingTimeInterval(-150), startedDate: pending ? nil : started,
            finishedDate: nil, executionProgress: pending ? .pending : .running, completionStatus: nil, startReason: nil,
            workflowID: workflow, workflowName: "Release", sourceBranchOrTag: "main"
        )
    }

    /// Sextant ends in 6 min, Hyrox in 2, Cumulus has no estimate, Delta is queued, Echo ends in 9: five builds.
    private func five() -> BuildSnapshot {
        let runs = history("w0", product: "p0", minutes: 10) + history("w1", product: "p1", minutes: 10) + history("w4", product: "p4", minutes: 10)
            + [
                running("sextant", product: "p0", workflow: "w0", startedMinutesAgo: 4, number: 412),
                running("hyrox", product: "p1", workflow: "w1", startedMinutesAgo: 8, number: 209),
                running("cumulus", product: "p2", workflow: "w2", startedMinutesAgo: 3, number: 56),
                running("delta", product: "p3", workflow: "w3", startedMinutesAgo: nil, pending: true, number: 3),
                running("echo", product: "p4", workflow: "w4", startedMinutesAgo: 1, number: 7),
            ]
        return BuildSnapshot(products: products(), runs: runs)
    }

    private func list(_ snapshot: BuildSnapshot, filter: BuildFilter = .all, query: String = "", scope: BuildListScope = .allBuilds, splits: Bool = true) -> BuildListModel {
        BuildListModel(snapshot: snapshot, scope: scope, filter: filter, query: query, splitsRunning: splits, now: now, locale: english)
    }

    // MARK: Which builds

    @Test func theBlockTakesTheThreeBuildsThatEndFirstThenThoseWithoutEstimateThenTheQueued() {
        let model = list(five())

        #expect(model.runningIDs == ["hyrox", "sextant", "echo"])
        #expect(model.moreRunning == 2)
    }

    @Test func theOthersStayInTheListAndNoBuildIsInBothPlaces() {
        let model = list(five())
        let listed = model.groups.flatMap(\.rows).map(\.id)

        #expect(Set(listed).isDisjoint(with: model.runningIDs))
        #expect(listed.contains("cumulus") && listed.contains("delta"))
        #expect(model.count == 5 + 9)
        #expect(model.rows.count == model.count)
        #expect(Array(model.rows.prefix(3).map(\.id)) == model.runningIDs)
    }

    @Test func theBlockIsLeftOutUnlessTheListAsksForIt() {
        let model = list(five(), splits: false)

        #expect(model.runningRows.isEmpty)
        #expect(model.moreRunning == 0)
        #expect(model.groups.flatMap(\.rows).count == 14)
    }

    @Test func noBlockWhenNothingRunsInWhatTheListShows() {
        let snapshot = BuildSnapshot(products: products(), runs: history("w0", product: "p0", minutes: 10))

        #expect(list(snapshot).runningRows.isEmpty)
        #expect(list(five(), scope: .product("p9")).runningRows.isEmpty)
    }

    @Test func theScopeAndTheSearchNarrowTheBlock() {
        #expect(list(five(), scope: .product("p1")).runningIDs == ["hyrox"])
        #expect(list(five(), scope: .workflow("w2")).runningIDs == ["cumulus"])
        #expect(list(five(), query: "sextant").runningIDs == ["sextant"])
        #expect(list(five(), query: "sextant").moreRunning == 0)
        #expect(list(five(), query: "#412").runningIDs == ["sextant"])
    }

    @Test func allAndRunningShowTheBlockFailuresAndTestFlightDoNot() {
        #expect(!list(five(), filter: .all).runningRows.isEmpty)
        #expect(list(five(), filter: .running).runningIDs == ["hyrox", "sextant", "echo"])
        #expect(list(five(), filter: .failed).runningRows.isEmpty)
        #expect(list(five(), filter: .testFlight).runningRows.isEmpty)
    }

    @Test func underTheRunningFilterTheOthersAreInTheListSoThereIsNoLineAboutThem() {
        let model = list(five(), filter: .running)

        #expect(model.moreRunning == 0)
        #expect(model.groups.flatMap(\.rows).map(\.id).sorted() == ["cumulus", "delta"])
    }

    @Test func theBlockAloneDoesNotMakeAnEmptyList() {
        let snapshot = BuildSnapshot(products: products(), runs: history("w0", product: "p0", minutes: 10) + [running("sextant", product: "p0", workflow: "w0", startedMinutesAgo: 4)])
        let model = list(snapshot, filter: .running)

        #expect(model.emptyReason == nil)
        #expect(model.groups.isEmpty)
        #expect(model.count == 1)
    }

    @Test func theOrderIsTheMenusOwn() {
        let snapshot = five()
        let block = RunningBlockModel(ids: list(snapshot).runningIDs, more: 2, snapshot: snapshot, now: now, locale: english)
        let menu = RunningBuildLine.lines(in: snapshot, now: now, locale: english).prefix(3)

        #expect(block.items.map(\.id) == menu.map(\.runID))
        #expect(RunningBuildsETA.entries(in: snapshot, now: now).map(\.run.id) == ["hyrox", "sextant", "echo", "cumulus", "delta"])
    }

    // MARK: Words

    @Test func aBuildSaysItsActionAndItsEnd() throws {
        let snapshot = five()
        let block = RunningBlockModel(ids: ["sextant"], more: 0, snapshot: snapshot, now: now, locale: english)
        let item = try #require(block.items.first)

        #expect(item.title == "Sextant #412")
        #expect(item.centerText == "~6 min")
        #expect(item.centerDetail?.hasPrefix("ends ~") == true)
        #expect(item.detail.contains("ends ~"))
        #expect(item.reference == "main")
        #expect(item.spoken.hasPrefix("Sextant #412, Release, main"))
        #expect(item.spoken.hasSuffix("estimated end in 6 minutes"))
        #expect(item.initial == "S")
    }

    @Test func aBuildWithoutEstimateShowsItsElapsedTime() throws {
        let block = RunningBlockModel(ids: ["cumulus"], more: 0, snapshot: five(), now: now, locale: english)
        let item = try #require(block.items.first)

        #expect(item.centerText == "3:00")
        #expect(item.centerDetail?.hasPrefix("started") == true)
        #expect(!item.detail.contains("ends ~"))
    }

    @Test func aQueuedBuildSaysHowLongItHasWaited() throws {
        let block = RunningBlockModel(ids: ["delta"], more: 0, snapshot: five(), now: now, locale: english)
        let item = try #require(block.items.first)

        #expect(item.isQueued)
        #expect(item.detail == "In queue for 2 min")
        #expect(item.centerText == "Queued")
        #expect(item.ring.state == .queued)
    }

    @Test func aBuildQueuedForLessThanAMinuteSaysSo() throws {
        let queued = CIBuildRun(
            id: "q", productID: "p3", number: 3, createdDate: now.addingTimeInterval(-20), startedDate: nil, finishedDate: nil,
            executionProgress: .pending, completionStatus: nil, startReason: nil, workflowID: "w3", workflowName: "Release", sourceBranchOrTag: "main"
        )
        let block = RunningBlockModel(ids: ["q"], more: 0, snapshot: BuildSnapshot(products: products(), runs: [queued]), now: now, locale: english)

        #expect(block.items.first?.detail == "In queue")
    }

    @Test func theBlockCountsAllTheBuildsThatRun() {
        let snapshot = five()
        let block = RunningBlockModel(ids: list(snapshot).runningIDs, more: 2, snapshot: snapshot, now: now, locale: english)

        #expect(block.items.count == 3)
        #expect(block.total == 5)
        #expect(block.spokenCount(locale: english) == "5 builds running")
        #expect(block.moreText(locale: english) == "and 2 others running")
        #expect(block.centerCount(locale: english).text == "5")
    }

    @Test func theLegendNamesAppsByIconOnlyWhenTheBuildsAreOfSeveralApps() {
        let mixed = RunningBlockModel(ids: ["sextant", "hyrox", "cumulus"], more: 0, snapshot: five(), now: now, locale: english)
        #expect(mixed.mixesApps)
        #expect(Set(mixed.items.map(\.productID)) == ["p0", "p1", "p2"])

        let sameApp = BuildSnapshot(products: products(), runs: [
            running("a", product: "p0", workflow: "w0", startedMinutesAgo: 4, number: 1),
            running("b", product: "p0", workflow: "w0", startedMinutesAgo: 3, number: 2),
        ])
        #expect(!RunningBlockModel(ids: ["a", "b"], more: 0, snapshot: sameApp, now: now, locale: english).mixesApps)
        #expect(!RunningBlockModel(ids: ["sextant"], more: 0, snapshot: five(), now: now, locale: english).mixesApps)
    }

    @Test func oneBuildIsSaidInTheSingular() {
        #expect(RunningBlockModel.Words.count(1, locale: english) == "1 build running")
        #expect(RunningBlockModel.Words.count(1, locale: french) == "1 build en cours")
        #expect(RunningBlockModel.Words.more(2, locale: french) == "et 2 autres en cours")
        #expect(RunningBlockModel.Words.more(1, locale: english) == "and 1 other running")
    }

    // MARK: Tapping the rings

    @Test func aTapOnTheRingsFindsTheNearestOne() {
        let size: CGFloat = 120
        let line: CGFloat = 10
        let middle = size / 2
        // Ring 0 is at radius 55, ring 1 at 42, ring 2 at 29.
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: middle, y: middle - 55), size: size, lineWidth: line, count: 3) == 0)
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: middle + 42, y: middle), size: size, lineWidth: line, count: 3) == 1)
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: middle, y: middle + 29), size: size, lineWidth: line, count: 3) == 2)
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: middle, y: middle), size: size, lineWidth: line, count: 3) == 2)
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: 0, y: 0), size: size, lineWidth: line, count: 3) == 0)
        #expect(RunningBlockHit.ringIndex(at: CGPoint(x: middle, y: middle - 55), size: size, lineWidth: line, count: 2) == 0)
    }
}
