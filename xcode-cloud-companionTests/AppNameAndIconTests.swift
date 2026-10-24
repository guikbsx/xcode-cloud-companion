import AppKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private let elan = CIProduct(id: "p1", name: "realmotivation", productType: "APP", appID: "app-1", appName: "Crossfit Hyrox Tracker : Élan", bundleID: "com.example.elan")
private let framework = CIProduct(id: "p2", name: "Toolkit", productType: "FRAMEWORK", appID: nil, appName: nil, bundleID: nil)

private func run(_ number: Int, product: String = "p1", progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded) -> CIBuildRun {
    CIBuildRun(
        id: "run-\(number)", productID: product, number: number, createdDate: now.addingTimeInterval(Double(number) * 60), startedDate: now,
        finishedDate: now.addingTimeInterval(600), executionProgress: progress, completionStatus: status, startReason: nil,
        workflowID: "w1", workflowName: "Release", sourceBranchOrTag: "main"
    )
}

private let snapshot = BuildSnapshot(products: [elan, framework], runs: [run(42), run(7, product: "p2")], lastSuccessfulSync: now)

struct AppDisplayNameTests {
    @Test func anAppGoesByItsStoreNameAndAnythingElseByItsProductName() {
        #expect(elan.displayName == "Crossfit Hyrox Tracker : Élan")
        #expect(framework.displayName == "Toolkit")
        #expect(CIProduct(id: "p", name: "Kit", productType: nil, appID: "a", appName: "  ", bundleID: nil).displayName == "Kit")
        #expect(snapshot.displayNames == ["realmotivation": "Crossfit Hyrox Tracker : Élan", "Toolkit": "Toolkit"])
    }

    @Test func theColourAndTheMinutesStayKeyedByTheProductName() {
        var palette = AppPalette()
        palette.update(ranking: ["realmotivation", "Toolkit"])
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: palette)
        let row = content.products.first { $0.id == "p1" }

        #expect(row?.name == "Crossfit Hyrox Tracker : Élan")
        #expect(row?.swatch == palette.swatch(for: "realmotivation"))

        let renamed = BuildSnapshot(
            products: [CIProduct(id: "p1", name: "realmotivation", productType: "APP", appID: "app-1", appName: "Élan", bundleID: nil), framework],
            runs: snapshot.runs, lastSuccessfulSync: now
        )
        #expect(SidebarContent(snapshot: renamed, pinnedIDs: [], palette: palette).products.first { $0.id == "p1" }?.swatch == row?.swatch)

        let summary = UsageSummary(
            plan: UsagePlan(hours: 25, resetAnchor: now), cycle: DateInterval(start: now.addingTimeInterval(-86_400), duration: 30 * 86_400), now: now,
            billedMinutes: 40, estimatedMinutes: 0, estimatedBuildCount: 0, lastImport: now, daily: [], buildsLast30Days: 2,
            byApp: [AppUsage(product: "realmotivation", billedMinutes: 40)],
            byWorkflow: [WorkflowUsage(product: "realmotivation", workflow: "Release", billedMinutes: 40, buildCount: 1)],
            costliestBuild: BuildCost(product: "realmotivation", buildNumber: 42, workflow: "Release", minutes: 40, isEstimated: false)
        )
        let overview = OverviewModel(summary: summary, palette: palette, displayNames: snapshot.displayNames)
        #expect(overview.apps.map(\.name) == ["realmotivation"])
        #expect(overview.apps.map(\.displayName) == ["Crossfit Hyrox Tracker : Élan"])
        #expect(overview.apps.first?.billedMinutes == 40)
        #expect(overview.workflows.first?.product == "Crossfit Hyrox Tracker : Élan")
        #expect(overview.costliestBuild?.product == "Crossfit Hyrox Tracker : Élan")
        #expect(OverviewModel(summary: summary, palette: palette).apps.first?.displayName == "realmotivation")
    }

    @Test func theWindowShowsTheStoreName() {
        let list = BuildListModel(snapshot: snapshot, scope: .product("p1"), now: now)
        #expect(list.title == "Crossfit Hyrox Tracker : Élan")
        #expect(list.rows.map(\.productName) == ["Crossfit Hyrox Tracker : Élan"])
        #expect(list.rows.first?.detail == "Crossfit Hyro… · Release · main")
        #expect(list.rows.first?.spokenDetail == "Crossfit Hyrox Tracker : Élan · Release · main")
        #expect(list.rows.first?.matches("realmotiv") == true)
        #expect(list.rows.first?.matches("hyrox") == true)

        let sheet = BuildDetailModel(run: run(42), product: elan, workflow: nil, actions: [], teamID: nil, now: now)
        #expect(sheet.appName == "Crossfit Hyrox Tracker : Élan")
        #expect(sheet.title == "Crossfit Hyrox Tracker : Élan · Release")

        var workflow = CIWorkflow(id: "w1", name: "Release", testDestinationCounts: [])
        workflow.productID = "p1"
        let sidebar = SidebarContent(snapshot: BuildSnapshot(products: [elan], runs: [run(42)], workflows: [workflow]), pinnedIDs: ["w1"], palette: AppPalette())
        #expect(sidebar.pinned.first?.productName == "Crossfit Hyrox Tracker : Élan")
    }

    @MainActor
    @Test func theMenuShowsTheStoreNameCutByItsUsualRule() throws {
        #expect(LatestBuildsMenu.plainTitle(run(42), product: elan) == "Crossfit Hyro… #42 · Release")
        #expect(LatestBuildsMenu.plainTitle(run(7, product: "p2"), product: framework) == "Toolkit #7 · Release")
        let voiceOver = LatestBuildsMenu.accessibilityLabel(run(42), product: elan, status: .succeeded, age: "4m")
        #expect(voiceOver.hasPrefix("Crossfit Hyro… #42 · Release"))

        let summary = UsageSummary(
            plan: UsagePlan(hours: 25, resetAnchor: now), cycle: DateInterval(start: now.addingTimeInterval(-86_400), duration: 30 * 86_400), now: now,
            billedMinutes: 40, estimatedMinutes: 0, estimatedBuildCount: 0, lastImport: now, daily: [], buildsLast30Days: 2,
            byApp: [AppUsage(product: "realmotivation", billedMinutes: 40)]
        )
        let items = AppBuildsMenu.items(snapshot: snapshot, summary: summary, now: now, open: { _ in })
        let row = try #require(items.first { $0.attributedTitle?.string.hasSuffix("Crossfit Hyrox Tracker : Élan") == true })
        #expect(row.badge?.stringValue == UsageFormat.compactMinutes(40))
    }

    @Test func aNotificationNamesTheAppByItsStoreName() {
        let before = BuildSnapshot(products: [elan], runs: [run(42, progress: .running, status: nil)], lastSuccessfulSync: now.addingTimeInterval(-60))
        let after = BuildSnapshot(products: [elan], runs: [run(42)], lastSuccessfulSync: now)

        let notes = BuildNotificationPlanner.finished(previous: before, current: after, rules: BuildNotificationRules(), now: now.addingTimeInterval(700))

        #expect(notes.map(\.title) == ["Crossfit Hyrox Tracker : Élan #42 succeeded"])
    }
}

struct AppIconDecodingTests {
    @Test func everyAppComesWithTheIconOfTheBuildAppleIncluded() throws {
        let page = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIAppIconsAttributes>.self, from: Fixture.data("appIcons"))

        let icons = page.appIcons
        #expect(Set(icons.keys) == ["app-1", "app-mac"])
        #expect(icons["app-1"]?.templateURL == "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/00/49/48/sample-old/logo60x60@2x.png/{w}x{h}bb.{f}")
        #expect(icons["app-1"]?.isMacIcon == false)
        #expect(icons["app-mac"]?.isMacIcon == true)
    }

    @Test func theNewestBuildOfEachAppGivesItsCurrentIcon() throws {
        let page = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildIconAttributes>.self, from: Fixture.data("latestBuildIcons"))

        let icons = page.appIcons
        #expect(Set(icons.keys) == ["app-1"])
        #expect(icons["app-1"]?.templateURL.contains("sample-new") == true)
    }

    @Test func theImageAddressFillsTheTemplateAndOnlyTrustsApplesImageServers() {
        let icon = CIAppIcon(templateURL: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/7c/f2/8e/sample-mac/logo.icns/{w}x{h}bb.{f}")

        #expect(icon.imageURL(pixels: 128)?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/7c/f2/8e/sample-mac/logo.icns/128x128bb.png")
        #expect(CIAppIcon(templateURL: "http://is1-ssl.mzstatic.com/a/{w}x{h}bb.{f}").imageURL(pixels: 128) == nil)
        #expect(CIAppIcon(templateURL: "https://example.com/a/{w}x{h}bb.{f}").imageURL(pixels: 128) == nil)
        #expect(CIAppIcon(templateURL: "https://notmzstatic.com/a/{w}x{h}bb.{f}").imageURL(pixels: 128) == nil)
        #expect(CIAppIcon(templateURL: "https://mzstatic.com.example.com/a/{w}x{h}bb.{f}").imageURL(pixels: 128) == nil)
    }

    @Test func theRequestsAskOnlyForTheIconToken() {
        let apps = AppStoreConnectEndpoint.appIcons
        #expect(apps.path() == "/v1/apps")
        #expect(URLRequest(url: apps).queryValue("fields[builds]") == "iconAssetToken")
        #expect(URLRequest(url: apps).queryValue("fields[apps]") == "builds")
        #expect(URLRequest(url: apps).queryValue("limit[builds]") == "1")

        let builds = AppStoreConnectEndpoint.latestBuildIcons
        #expect(builds.path() == "/v1/builds")
        #expect(URLRequest(url: builds).queryValue("fields[builds]") == "iconAssetToken,app")
        #expect(URLRequest(url: builds).queryValue("sort") == "-uploadedDate")
    }
}

struct AppIconSyncTests {
    private func reply(_ request: URLRequest, iconsFail: Bool = false) -> MockTransport.Reply {
        let path = request.url?.path() ?? ""
        switch path {
        case "/v1/ciProducts": return MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data())
        case "/v1/apps": return iconsFail ? MockTransport.Reply(status: 403) : MockTransport.Reply(body: (try? Fixture.data("appIcons")) ?? Data())
        case "/v1/builds": return MockTransport.Reply(body: (try? Fixture.data("latestBuildIcons")) ?? Data())
        default: return MockTransport.Reply(body: Data(#"{"data": [], "links": {}}"#.utf8))
        }
    }

    private func iconRequests(_ transport: MockTransport) async -> [String] {
        await transport.requests.compactMap { $0.url?.path() }.filter { $0 == "/v1/apps" || $0 == "/v1/builds" }
    }

    @Test func iconsAreAskedOnceThenOnlyOnceADayFromTheNewestBuilds() async throws {
        let transport = MockTransport { reply($0) }
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let first = try await synchronizer.sync(from: .empty, now: now)
        // Only the app of a product is kept: "app-mac" is not built by Xcode Cloud here.
        #expect(Set(first.appIcons.keys) == ["app-1"])
        #expect(first.appIcons["app-1"]?.templateURL.contains("sample-old") == true)
        #expect(first.appIconsCheckedAt == now)
        #expect(first.icon(of: first.products.first)?.templateURL.contains("sample-old") == true)
        #expect(await iconRequests(transport) == ["/v1/apps"])

        let soon = try await synchronizer.sync(from: first, now: now.addingTimeInterval(3600))
        #expect(soon.appIcons == first.appIcons)
        #expect(await iconRequests(transport) == ["/v1/apps"])

        let nextDay = try await synchronizer.sync(from: soon, now: now.addingTimeInterval(25 * 3600))
        #expect(nextDay.appIcons["app-1"]?.templateURL.contains("sample-new") == true)
        #expect(await iconRequests(transport) == ["/v1/apps", "/v1/builds"])
    }

    @Test func aRefusalNeverFailsTheSyncAndIsRetriedLater() async throws {
        let transport = MockTransport { reply($0, iconsFail: true) }
        let synchronizer = BuildSynchronizer(client: AppStoreConnectClient(credentials: .sample(), transport: transport))

        let first = try await synchronizer.sync(from: .empty, now: now)
        #expect(first.appIcons.isEmpty)
        #expect(first.products.count == 2)

        _ = try await synchronizer.sync(from: first, now: now.addingTimeInterval(600))
        #expect(await iconRequests(transport) == ["/v1/apps"])

        _ = try await synchronizer.sync(from: first, now: now.addingTimeInterval(3700))
        #expect(await iconRequests(transport) == ["/v1/apps", "/v1/apps"])
    }

    @Test func aCacheWrittenBeforeIconsExistedStillLoads() throws {
        let old = try JSONDecoder().decode(BuildSnapshot.self, from: Data(#"{"products": [], "runs": []}"#.utf8))

        #expect(old.appIcons.isEmpty)
        #expect(old.appIconsCheckedAt == nil)
    }
}

/// A 1 × 1 PNG, enough to stand in for an icon.
private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

private final class DownloadCounter: Sendable {
    let urls = Mutex<[URL]>([])
}

struct AppIconCacheTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "AppIcons-\(UUID().uuidString)")
    private let icon = CIAppIcon(templateURL: "https://is1-ssl.mzstatic.com/image/thumb/a/logo.png/{w}x{h}bb.{f}")

    private func cache(_ counter: DownloadCounter, data: Data? = pngData) -> AppIconCache {
        AppIconCache(directory: directory) { url in
            counter.urls.withLock { $0.append(url) }
            return data
        }
    }

    @Test func anIconIsDownloadedOnceThenReadFromDisk() async {
        let counter = DownloadCounter()

        #expect(await cache(counter).imageData(appID: "app-1", icon: icon) == pngData)
        #expect(await cache(counter).imageData(appID: "app-1", icon: icon) == pngData)

        #expect(counter.urls.withLock { $0.map(\.absoluteString) } == ["https://is1-ssl.mzstatic.com/image/thumb/a/logo.png/128x128bb.png"])
    }

    @Test func aNewTokenIsDownloadedAndReplacesTheOldFile() async throws {
        let counter = DownloadCounter()
        _ = await cache(counter).imageData(appID: "app-1", icon: icon)
        let changed = CIAppIcon(templateURL: "https://is1-ssl.mzstatic.com/image/thumb/b/logo.png/{w}x{h}bb.{f}")

        #expect(await cache(counter).imageData(appID: "app-1", icon: changed) == pngData)

        #expect(counter.urls.withLock { $0.count } == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path())
        #expect(files == ["app-1-\(AppIconCache.fingerprint(of: changed)).png"])
    }

    @Test func whatIsNotAnImageOrNotFromAppleIsRefused() async {
        let counter = DownloadCounter()

        #expect(await cache(counter, data: Data("<html>".utf8)).imageData(appID: "app-1", icon: icon) == nil)
        #expect(await cache(counter, data: nil).imageData(appID: "app-1", icon: icon) == nil)
        #expect(await cache(counter).imageData(appID: "../x", icon: icon) == nil)
        let elsewhere = CIAppIcon(templateURL: "https://example.com/logo.png/{w}x{h}bb.{f}")
        #expect(await cache(counter).imageData(appID: "app-2", icon: elsewhere) == nil)
        #expect(counter.urls.withLock { $0.count } == 2)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? [] == [])
    }

    @MainActor
    @Test func theMenuReadsOnlyWhatIsAlreadyOnTheDisk() async {
        let counter = DownloadCounter()
        let snapshot = BuildSnapshot(products: [elan, framework], appIcons: ["app-1": icon])

        #expect(cache(counter).cachedArtwork(of: ["p1", "p2"], in: snapshot).isEmpty)
        _ = await cache(counter).imageData(appID: "app-1", icon: icon)
        let artwork = cache(counter).cachedArtwork(of: ["p1", "p2"], in: snapshot)

        #expect(Set(artwork.keys) == ["p1"])
        #expect(artwork["p1"]?.isMacIcon == false)
        #expect(counter.urls.withLock { $0.count } == 1)
    }

    @MainActor
    @Test func theStoreShowsWhatLoadedAndLeavesTheInitialOtherwise() async {
        let counter = DownloadCounter()
        let store = AppIconStore(cache: cache(counter))
        let withIcon = BuildSnapshot(products: [elan, framework], appIcons: ["app-1": icon])

        #expect(store.artwork(of: elan, in: withIcon) == nil)
        await store.load(withIcon.appIcons)
        await store.load(withIcon.appIcons)

        #expect(store.artwork(of: elan, in: withIcon)?.isMacIcon == false)
        #expect(store.artwork(of: framework, in: withIcon) == nil)
        #expect(Set(store.artwork(in: withIcon, by: \.id).keys) == ["p1"])
        #expect(counter.urls.withLock { $0.count } == 1)

        let emptyDirectory = FileManager.default.temporaryDirectory.appending(path: "AppIcons-\(UUID().uuidString)")
        let failing = AppIconStore(cache: AppIconCache(directory: emptyDirectory) { _ in nil })
        await failing.load(withIcon.appIcons)
        #expect(failing.artwork(of: elan, in: withIcon) == nil)
    }
}
