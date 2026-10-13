import Foundation
import Testing
@testable import XcodeCloudCompanion

struct WidgetFeedTests {
    private let now = CLIFixture.now
    private let coral = SwatchColor(red: 0.85, green: 0.36, blue: 0.29)

    private var palette: AppPalette {
        var palette = AppPalette()
        palette.update(ranking: CLIFixture.products.map(\.name))
        palette.setIconReading(AppPalette.IconReading(icon: "a", color: coral), for: "Alpha")
        return palette
    }

    private func summary(_ snapshot: BuildSnapshot) -> UsageSummary {
        UsageCalculator.summary(snapshot: snapshot, ledger: CLIFixture.ledger, plan: CLIFixture.plan, now: now)
    }

    private var measured: BuildSnapshot {
        var snapshot = CLIFixture.snapshot
        snapshot.testDevicesByActionID["b8-test"] = [CITestDeviceRun(deviceName: "iPhone 16", osVersion: "18.0", testCount: 20, failedCount: 0, totalSeconds: 240)]
        return snapshot
    }

    @Test func theWidgetsShowTheNewestBuildsAndTheNewestOfEveryApp() {
        let feed = WidgetFeed.snapshot(of: CLIFixture.snapshot, summary: nil, palette: palette, now: now)

        #expect(feed.hasAccount && feed.cycle == nil)
        #expect(feed.apps.map(\.name) == ["Alpha", "Suite", "Suite"])
        #expect(feed.builds.first?.id == "run-g8" && feed.builds.first?.state == .running)
        #expect(feed.builds.map(\.id) == Array(feed.builds.map(\.id)).sorted { first, second in
            let dates = Dictionary(uniqueKeysWithValues: CLIFixture.snapshot.runs.map { ($0.id, $0.createdDate ?? .distantPast) })
            return (dates[first] ?? .distantPast) > (dates[second] ?? .distantPast)
        })
        for product in CLIFixture.products {
            #expect(feed.latestBuild(appID: product.id) != nil, "no build kept for \(product.name)")
        }
        #expect(feed.latestBuild(appID: "p-beta")?.id == "run-b10")
        #expect(feed.latestBuild(appID: nil)?.id == "run-g8")
        #expect(feed.recentBuilds(limit: 3).count == 3)
    }

    @Test func aBuildCarriesItsStateItsDurationAndTheColourOfItsApp() throws {
        let feed = WidgetFeed.snapshot(of: CLIFixture.snapshot, summary: nil, palette: palette, now: now)

        let failed = try #require(feed.builds.first { $0.id == "run-a44" })
        #expect(failed.state == .failed && failed.failedTests == 2 && failed.durationSeconds == 720)
        #expect(failed.title == "Alpha #44" && failed.url?.absoluteString == "cumulus://build/run-a44")
        #expect(failed.tint == AppSwatch.icon(coral.legible).widgetTint)

        let running = try #require(feed.builds.first { $0.id == "run-a45" })
        #expect(running.state == .running && running.durationSeconds == nil && running.date == CLIFixture.snapshot.runs.first { $0.id == "run-a45" }?.startedDate)

        let beta = try #require(feed.latestBuild(appID: "p-beta"))
        #expect(beta.app == "Suite" && beta.tint == AppSwatch.cyan.widgetTint)
    }

    @Test func theCycleIsTheFigureOfTheAppAndItsArcsFollowTheApps() throws {
        let snapshot = measured
        let summary = summary(snapshot)
        let feed = WidgetFeed.snapshot(of: snapshot, summary: summary, palette: palette, now: now)
        let cycle = try #require(feed.cycle)

        #expect(!cycle.isMeasuring && cycle.isEstimate)
        #expect(cycle.usedMinutes == summary.usedMinutes && cycle.quotaMinutes == 1500)
        #expect(cycle.percentUsed == Int((summary.writtenFractionUsed * 100).rounded()))
        #expect(cycle.segments.map(\.app) == summary.byApp.filter { $0.totalMinutes > 0 }.map { snapshot.displayNames[$0.product] ?? $0.product })
        let arcs = cycle.arcs
        #expect(arcs.count == cycle.segments.count)
        #expect(arcs.first?.start == 0)
        for (previous, next) in zip(arcs, arcs.dropFirst()) {
            #expect(previous.end == next.start)
        }
        #expect(abs((arcs.last?.end ?? 0) - summary.usedMinutes / 1500) < 0.0001)
        #expect(feed.cycleFace == .cycle(cycle))
    }

    @Test func whileBuildsAreMeasuredTheWidgetsShowNoFigure() {
        let feed = WidgetFeed.snapshot(of: CLIFixture.snapshot, summary: summary(CLIFixture.snapshot), palette: palette, now: now)

        #expect(feed.cycle?.isMeasuring == true)
        #expect(feed.cycleFace == .measuring)
    }

    @Test func aCycleOverThePlanStopsAtTheFullRing() {
        let tint = WidgetSnapshot.Tint(red: 0, green: 0, blue: 0)
        let cycle = WidgetSnapshot.Cycle(
            usedMinutes: 2000, quotaMinutes: 1000, percentUsed: 200, isEstimate: false, isMeasuring: false, resetDate: now,
            segments: [.init(app: "A", minutes: 800, tint: tint), .init(app: "B", minutes: 700, tint: tint), .init(app: "C", minutes: 500, tint: tint)]
        )

        #expect(cycle.arcs.map(\.end) == [0.8, 1])
    }

    @Test func eachWidgetKnowsWhatToSayWhenThereIsNothingToShow() {
        let empty = WidgetSnapshot.empty(at: now)
        #expect(empty.buildFace(appID: nil) == .noAccount && empty.cycleFace == .noAccount)

        let noBuilds = WidgetSnapshot(generatedAt: now, hasAccount: true)
        #expect(noBuilds.buildFace(appID: nil) == .noBuild && noBuilds.cycleFace == .noPlan)

        let feed = WidgetFeed.snapshot(of: CLIFixture.snapshot, summary: nil, palette: palette, now: now)
        #expect(feed.buildFace(appID: "gone") == .noBuild)
    }

    @Test func theFileIsReadBackAndAnotherVersionsFileIsNot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        #expect(store.load() == nil)

        let feed = WidgetFeed.snapshot(of: measured, summary: summary(measured), palette: palette, now: now)
        #expect(store.save(feed))
        #expect(store.load() == feed)

        var future = feed
        future.schema = WidgetSnapshot.currentSchema + 1
        #expect(store.save(future))
        #expect(store.load() == nil)
    }
}

@MainActor
private final class Reloads {
    var count = 0
}

@MainActor
struct WidgetFeedWriterTests {
    @Test func theWidgetsAreToldOnlyWhenWhatTheyShowChanged() async throws {
        let accounts = TestAccounts()
        let session = try await accounts.add("Work")
        let directory = FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let reloads = Reloads()
        let writer = WidgetFeedWriter(store: store) { reloads.count += 1 }
        let now = Date(timeIntervalSince1970: 1_791_892_800)

        await writer.update(for: session, now: now)
        await writer.update(for: session, now: now.addingTimeInterval(60))
        #expect(reloads.count == 1)
        #expect(store.load()?.hasAccount == true && store.load()?.generatedAt == now)

        await writer.update(for: nil, now: now.addingTimeInterval(120))
        #expect(reloads.count == 2)
        #expect(store.load()?.hasAccount == false)
    }
}
