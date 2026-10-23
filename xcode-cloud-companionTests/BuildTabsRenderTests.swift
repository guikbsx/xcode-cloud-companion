import AppKit
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

@MainActor @Observable
private final class TabModel {
    var tab: BuildTab
    init(_ tab: BuildTab) { self.tab = tab }
}

private struct SlowTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .milliseconds(300))
        let response = HTTPURLResponse(url: request.url ?? URL(filePath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"data": []}"#.utf8), response)
    }
}

private struct Host: View {
    @Bindable var model: TabModel
    let run: CIBuildRun
    let buildStore: BuildStore
    let extras: BuildExtrasStore
    let saver: ArtifactSaver

    var body: some View {
        BuildDetailView(run: run, buildStore: buildStore, extrasStore: extras, artifactSaver: saver, teamID: nil, tab: $model.tab)
    }
}

/// The tabs of a build, drawn for real while the tabs below them load: what the pills show depends on the tab chosen, not on the
/// ones chosen before (XCO-178: pills that were not selected lost their labels once another tab had been chosen).
@MainActor
struct BuildTabsRenderTests {
    private let day = Date(timeIntervalSince1970: 1_791_547_200)
    private let size = CGSize(width: 560, height: 700)

    private func rig(directory: URL) async throws -> (run: CIBuildRun, store: BuildStore, extras: BuildExtrasStore, saver: ArtifactSaver) {
        let run = CIBuildRun(
            id: "run-1", productID: "p1", number: 42, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(372),
            executionProgress: .complete, completionStatus: .succeeded, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Release",
            sourceBranchOrTag: "main"
        )
        let action = CIBuildAction(
            id: "archive", buildRunID: "run-1", name: "Archive - macOS", actionType: .archive, startedDate: day, finishedDate: day.addingTimeInterval(300),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: true, issueCounts: nil
        )
        let cache = BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json"))
        try await cache.save(BuildSnapshot(
            products: [CIProduct(id: "p1", name: "cart", productType: "APP", appID: "1", appName: "Cart", bundleID: nil)], runs: [run],
            actionsByRunID: ["run-1": [action]]
        ))
        let store = BuildStore(cacheStore: cache)
        await store.loadCacheIfNeeded()
        let client = AppStoreConnectClient(credentials: .sample(), transport: SlowTransport())
        return (run, store, BuildExtrasStore(cache: BuildExtrasCache(directory: directory.appending(path: "details")), client: { client }), ArtifactSaver(client: { client }))
    }

    private func makeWindow(_ model: TabModel, dark: Bool, _ rig: (run: CIBuildRun, store: BuildStore, extras: BuildExtrasStore, saver: ArtifactSaver)) -> (NSWindow, NSView) {
        let root = Host(model: model, run: rig.run, buildStore: rig.store, extras: rig.extras, saver: rig.saver)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        return (window, hosting)
    }

    /// The strip of the window that holds the pills.
    private func pills(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let strip = NSRect(x: 0, y: 280, width: size.width, height: 40)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        guard let cropped = rep.cgImage?.cropping(to: CGRect(x: 0, y: strip.minY * scale, width: strip.width * scale, height: strip.height * scale)) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    @Test(arguments: [false, true])
    func thePillsLookTheSameWhateverTabsWereChosenBefore(dark: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try await rig(directory: directory)
        let model = TabModel(.actions)
        let (window, view) = makeWindow(model, dark: dark, rig)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        for tab in [BuildTab.tests, .problems, .artifacts, .actions] {
            model.tab = tab
            for wait in [100, 800] {
                try await Task.sleep(for: .milliseconds(wait))
                let fresh = TabModel(tab)
                let (freshWindow, freshView) = makeWindow(fresh, dark: dark, rig)
                defer { freshWindow.close() }
                try await Task.sleep(for: .milliseconds(300))

                let seen = try #require(pills(of: view))
                let expected = try #require(pills(of: freshView))
                if seen != expected {
                    Attachment.record(seen, named: "\(dark ? "dark" : "light")-\(tab)-\(wait)ms-seen.png")
                    Attachment.record(expected, named: "\(dark ? "dark" : "light")-\(tab)-\(wait)ms-expected.png")
                }
                #expect(seen == expected, "the pills after choosing \(tab) (\(dark ? "dark" : "light"), \(wait) ms later) differ from the pills drawn with \(tab) from the start")
            }
        }
    }
}
