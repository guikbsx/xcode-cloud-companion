import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct LatestBuildsMenuTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func run(
        _ number: Int, product: String, minutesAgo: Double, progress: CIExecutionProgress = .complete,
        status: CICompletionStatus? = .succeeded, workflow: String? = "Release"
    ) -> CIBuildRun {
        let created = now.addingTimeInterval(-minutesAgo * 60)
        return CIBuildRun(
            id: "run-\(product)-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(600) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: nil, workflowName: workflow, sourceBranchOrTag: nil
        )
    }

    private func snapshot(_ runs: [CIBuildRun]) -> BuildSnapshot {
        BuildSnapshot(
            products: [
                CIProduct(id: "a", name: "Alpha", productType: "APP", appID: "111", appName: nil, bundleID: nil),
                CIProduct(id: "b", name: "A-very-long-app-name", productType: "APP", appID: "222", appName: nil, bundleID: nil),
            ],
            runs: runs
        )
    }

    @Test func fiveLatestBuildsAcrossAppsNewestFirst() {
        let runs = [
            run(1, product: "a", minutesAgo: 600), run(2, product: "b", minutesAgo: 500), run(3, product: "a", minutesAgo: 400),
            run(4, product: "b", minutesAgo: 30), run(5, product: "a", minutesAgo: 20), run(6, product: "b", minutesAgo: 10), run(7, product: "a", minutesAgo: 5),
        ]

        let items = LatestBuildsMenu.items(snapshot: snapshot(runs), now: now) { _ in }

        #expect(items.first?.isSectionHeader == true)
        #expect(items.dropFirst().count == 5)
        let builds: [String] = items.dropFirst().map { item in
            let text = item.attributedTitle?.string ?? ""
            return text.split(separator: "\t").last.map(String.init) ?? ""
        }
        let expected: [String] = ["#7 · Release", "#6 · Release", "#5 · Release", "#4 · Release", "#3 · Release"]
        #expect(builds == expected)
    }

    @Test func fewerThanFiveBuildsShowOnlyThoseAndNoBuildMeansNoSection() {
        let items = LatestBuildsMenu.items(snapshot: snapshot([run(1, product: "a", minutesAgo: 5)]), now: now) { _ in }

        #expect(items.count == 2)
        #expect(LatestBuildsMenu.items(snapshot: .empty, now: now) { _ in }.isEmpty)
    }

    @Test func eachBuildHasItsStatusDotAndTheNumberIsBold() throws {
        let runs = [
            run(1, product: "a", minutesAgo: 40, status: .failed), run(2, product: "a", minutesAgo: 30, status: .succeeded),
            run(3, product: "a", minutesAgo: 20, status: .canceled), run(4, product: "a", minutesAgo: 10, progress: .running),
        ]

        let items = LatestBuildsMenu.items(snapshot: snapshot(runs), now: now) { _ in }

        let colors: [NSColor?] = items.dropFirst().map { $0.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
        let expectedColors: [NSColor?] = [.systemBlue, .systemGray, .systemGreen, .systemRed]
        #expect(colors == expectedColors)
        let title = try #require(items.dropFirst().first?.attributedTitle)
        let text = title.string as NSString
        let numberFont = try #require(title.attribute(.font, at: text.range(of: "#4").location, effectiveRange: nil) as? NSFont)
        let workflowFont = try #require(title.attribute(.font, at: text.range(of: "Release").location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.weight(of: numberFont) > NSFontManager.shared.weight(of: workflowFont))
    }

    @Test func voiceOverReadsTheStateInWordsNotTheDot() throws {
        let items = LatestBuildsMenu.items(snapshot: snapshot([run(7, product: "a", minutesAgo: 90, status: .failed)]), now: now) { _ in }
        let item = try #require(items.last)

        #expect(item.accessibilityLabel() == "Alpha #7 · Release, Failed, 1h")
    }

    @Test func theAppColumnLinesUpAndLongNamesAreShortened() throws {
        let items = LatestBuildsMenu.items(snapshot: snapshot([run(9, product: "b", minutesAgo: 5)]), now: now) { _ in }
        let title = try #require(items.last?.attributedTitle)

        #expect(title.string.contains("A-very-long-a…\t#9"))
        let style = title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.tabStops.first?.location == LatestBuildsMenu.appColumnWidth)
    }

    @Test func aRunningBuildShowsItsElapsedTimeAndAFinishedOneItsAge() {
        let runs = [run(1, product: "a", minutesAgo: 190), run(2, product: "a", minutesAgo: 4, progress: .running)]

        let items = LatestBuildsMenu.items(snapshot: snapshot(runs), now: now) { _ in }

        #expect(items[1].badge?.stringValue == "4m")
        #expect(items[2].badge?.stringValue == "3h")
    }

    @Test func clickingOpensTheBuildInAppStoreConnect() throws {
        var opened: URL?
        let items = LatestBuildsMenu.items(snapshot: snapshot([run(1, product: "a", minutesAgo: 5)]), now: now) { opened = $0 }
        let build = try #require(items.last)

        (build.target as? MenuActionTarget)?.run(build)

        #expect(opened?.absoluteString == "https://appstoreconnect.apple.com/apps/111/ci/builds/run-a-1/summary")
        #expect(build.toolTip?.contains("run-a-1/summary") == true)
    }

    @Test func theHeaderCountsRunningBuilds() {
        let running = [run(1, product: "a", minutesAgo: 5, progress: .running), run(2, product: "b", minutesAgo: 3, progress: .pending)]

        #expect(LatestBuildsMenu.items(snapshot: snapshot(running), now: now) { _ in }.first?.title == "Latest builds · 2 running")
        #expect(LatestBuildsMenu.headerTitle(running: 0) == "Latest builds")
    }

    @Test func theMenuOpensOnTheLatestBuildsThenTheGauge() {
        let state = StatusMenuState(
            needsAPIKey: false, summary: nil, snapshot: snapshot([run(1, product: "a", minutesAgo: 5)]),
            lastSync: now, isSyncing: false, errorMessage: nil, now: now
        )

        let items = StatusMenuBuilder.items(for: state, actions: StatusMenuActions())

        #expect(items.first?.title == "Latest builds")
        #expect(items.dropFirst(2).first?.isSeparatorItem == true)
    }
}

struct AgeFormatTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    @Test(arguments: [(20.0, "now"), (59.0, "now"), (60.0, "1m"), (240.0, "4m"), (3_600.0, "1h"), (7_199.0, "1h"), (86_400.0, "1d"), (3 * 86_400.0, "3d")])
    func ageUsesTheLargestUnit(seconds: Double, expected: String) {
        #expect(UsageFormat.age(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func aFutureDateReadsAsNow() {
        #expect(UsageFormat.age(since: now.addingTimeInterval(120), now: now) == "now")
    }
}
