import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct AppBuildsMenuTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func run(_ number: Int, product: String, hoursAgo: Double, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded) -> CIBuildRun {
        let created = now.addingTimeInterval(-hoursAgo * 3600)
        return CIBuildRun(
            id: "run-\(product)-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(12 * 60) : nil,
            executionProgress: progress, completionStatus: status, startReason: nil,
            workflowID: nil, workflowName: "Release", sourceBranchOrTag: "main"
        )
    }

    private var snapshot: BuildSnapshot {
        BuildSnapshot(
            products: [
                CIProduct(id: "a", name: "Alpha", productType: "APP", appID: "111", appName: nil, bundleID: nil),
                CIProduct(id: "b", name: "Beta", productType: "APP", appID: "222", appName: nil, bundleID: nil),
                CIProduct(id: "c", name: "Never Built", productType: "APP", appID: "333", appName: nil, bundleID: nil),
            ],
            runs: [run(5, product: "b", hoursAgo: 1, progress: .running, status: nil), run(4, product: "b", hoursAgo: 30, status: .failed)]
                + (1...12).map { run($0, product: "a", hoursAgo: Double(100 - $0)) }
        )
    }

    @Test func appsWithBuildsAreListedMostRecentFirstAndOthersHidden() {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }

        #expect(items.first?.isSectionHeader == true)
        #expect(items.dropFirst().filter { !$0.isSeparatorItem }.map { $0.title.replacing(/^\S+ (\u{25A0} )?/, with: "") } == ["Beta", "Alpha"])
    }

    @Test func eachAppShowsItsTenLatestBuildsNewestFirst() throws {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }
        let alpha = try #require(items.first { $0.title.hasSuffix("Alpha") })

        let titles = alpha.submenu?.items.map(\.title) ?? []
        #expect(titles.count == 10)
        #expect(titles.first?.hasSuffix("#12 · Release") == true)
        #expect(titles.last?.hasSuffix("#3 · Release") == true)
    }

    @Test func aRunningBuildIsFlaggedOnItsApp() throws {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }

        #expect(items.first { $0.title.hasSuffix("Beta") }?.subtitle == "Building now · #5")
        #expect(items.first { $0.title.hasSuffix("Alpha") }?.subtitle == nil)
    }

    @Test func aBuildShowsStatusDurationAgeAndBranch() {
        let failed = run(4, product: "b", hoursAgo: 30, status: .failed)

        let subtitle = AppBuildsMenu.subtitle(for: failed, actions: [], now: now)

        #expect(subtitle.hasPrefix("Failed · 12"))
        #expect(subtitle.hasSuffix(" · main"))
    }

    @Test func theSectionIsTitledForTheCycle() {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }

        #expect(items.first?.title == "Apps · this cycle")
    }

    @Test func eachAppRowCarriesItsStatusDotAndItsOwnColour() throws {
        var palette = AppPalette()
        palette.update(ranking: ["Alpha", "Beta"])

        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, palette: palette, now: now) { _ in }

        let beta = try #require(items.first { $0.title.hasSuffix("Beta") })
        let square = ((beta.attributedTitle?.string ?? "") as NSString).range(of: "\u{25A0}").location
        #expect(beta.attributedTitle?.attribute(.foregroundColor, at: square, effectiveRange: nil) as? NSColor == palette.swatch(for: "Beta").nsColor)
        #expect(beta.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue)
        let alpha = try #require(items.first { $0.title.hasSuffix("Alpha") }?.attributedTitle)
        #expect(alpha.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemGreen)
    }

    @Test func buildsInTheSubmenuGetPlainStatusDots() throws {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }
        let first = try #require(items.first { $0.title.hasSuffix("Beta") }?.submenu?.items.first)

        #expect(first.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue)
    }

    @Test func clickingABuildOpensItInTheApp() throws {
        var opened: String?
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { opened = $0 }
        let build = try #require(items.first { $0.title.hasSuffix("Beta") }?.submenu?.items.first)

        (build.target as? MenuActionTarget)?.run(build)

        #expect(opened == "run-b-5")
    }

    @Test func cycleUsageAppearsAsABadge() throws {
        let plan = UsagePlan(hours: 25, resetAnchor: now.addingTimeInterval(10 * 86_400))
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(builds: [BilledBuild(product: "Alpha", buildNumber: 12, workflow: "Release", startedAt: now.addingTimeInterval(-88 * 3600), minutes: 42)], coverage: DateInterval(start: now, duration: 0)),
            fileName: "u.csv", modifiedAt: now, importedAt: now
        )
        let summary = UsageCalculator.summary(snapshot: snapshot, ledger: ledger, plan: plan, now: now)

        let items = AppBuildsMenu.items(snapshot: snapshot, summary: summary, now: now) { _ in }

        #expect(items.first { $0.title.hasSuffix("Alpha") }?.badge?.stringValue == UsageFormat.compactMinutes(42))
        #expect(items.first { $0.title.hasSuffix("Alpha") }?.badge?.stringValue == "42m")
    }

    @Test func noAppsMeansNoSection() {
        #expect(AppBuildsMenu.items(snapshot: .empty, summary: nil, now: now) { _ in }.isEmpty)
    }
}

@MainActor
struct BuildStatusTests {
    private func run(_ progress: CIExecutionProgress, _ status: CICompletionStatus?) -> CIBuildRun {
        CIBuildRun(
            id: "r", productID: "p", number: 1, createdDate: nil, startedDate: nil, finishedDate: nil,
            executionProgress: progress, completionStatus: status, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    @Test(arguments: [
        (CIExecutionProgress.pending, CICompletionStatus?.none, BuildStatus.running),
        (.running, nil, .running),
        (.complete, .succeeded, .succeeded),
        (.complete, .failed, .failed),
        (.complete, .errored, .errored),
        (.complete, .canceled, .canceled),
        (.complete, .skipped, .skipped),
        (.complete, nil, .finished),
        (.complete, .unknown("NEW"), .finished),
    ])
    func everyBuildMapsToOneStatus(progress: CIExecutionProgress, completion: CICompletionStatus?, expected: BuildStatus) {
        #expect(BuildStatus(run: run(progress, completion)) == expected)
    }

    @Test func eachStatusHasItsSystemColour() {
        #expect(BuildStatus.running.color == .systemBlue)
        #expect(BuildStatus.succeeded.color == .systemGreen)
        #expect(BuildStatus.failed.color == .systemRed)
        #expect(BuildStatus.errored.color == .systemOrange)
        #expect(BuildStatus.canceled.color == .systemGray)
    }

    @Test func aRunningBuildHasADistinctGlyphBeyondItsColour() {
        #expect(BuildStatusDot.glyph(for: .running) != BuildStatusDot.glyph(for: .failed))
        #expect(BuildStatusDot.glyph(for: .succeeded) == "\u{25CF}")
    }
}
