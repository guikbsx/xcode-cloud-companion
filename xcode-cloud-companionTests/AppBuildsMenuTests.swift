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
        #expect(items.dropFirst().filter { !$0.isSeparatorItem }.map(\.title) == ["Beta", "Alpha"])
    }

    @Test func eachAppShowsItsTenLatestBuildsNewestFirst() throws {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }
        let alpha = try #require(items.first { $0.title == "Alpha" })

        let titles = alpha.submenu?.items.map(\.title) ?? []
        #expect(titles.count == 10)
        #expect(titles.first == "#12 · Release")
        #expect(titles.last == "#3 · Release")
    }

    @Test func aRunningBuildIsFlaggedOnItsApp() throws {
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { _ in }

        #expect(items.first { $0.title == "Beta" }?.subtitle == "Building now")
        #expect(items.first { $0.title == "Alpha" }?.subtitle == nil)
    }

    @Test func aBuildShowsStatusDurationAgeAndBranch() {
        let failed = run(4, product: "b", hoursAgo: 30, status: .failed)

        let subtitle = AppBuildsMenu.subtitle(for: failed, actions: [], now: now)

        #expect(subtitle.hasPrefix("Failed · 12"))
        #expect(subtitle.hasSuffix(" · main"))
        #expect(AppBuildsMenu.statusSymbol(for: failed).name == "xmark.circle.fill")
        #expect(AppBuildsMenu.statusSymbol(for: run(1, product: "a", hoursAgo: 1)).color == .systemGreen)
    }

    @Test func clickingABuildOpensItInAppStoreConnect() throws {
        var opened: URL?
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: nil, now: now) { opened = $0 }
        let build = try #require(items.first { $0.title == "Beta" }?.submenu?.items.first)

        (build.target as? MenuActionTarget)?.run(build)

        #expect(opened?.absoluteString == "https://appstoreconnect.apple.com/apps/222/ci/builds/run-b-5/summary")
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

        #expect(items.first { $0.title == "Alpha" }?.badge?.stringValue == UsageFormat.minutes(42))
    }

    @Test func noAppsMeansNoSection() {
        #expect(AppBuildsMenu.items(snapshot: .empty, summary: nil, now: now) { _ in }.isEmpty)
    }
}
