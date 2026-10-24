import AppKit
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

private struct NoTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A build sheet in a real window over a snapshot and extras written to disk, as the app would have them.
@MainActor
struct SheetRig {
    enum Case: CaseIterable {
        case failedTests, compileFailure, running, delivered
    }

    let run: CIBuildRun
    let store: BuildStore
    let extras: BuildExtrasStore
    let saver: ArtifactSaver

    static let day = Date(timeIntervalSince1970: 1_791_547_200)

    private static func action(
        _ id: String, _ name: String, _ type: CIActionType, _ completion: CICompletionStatus?, progress: CIExecutionProgress = .complete,
        seconds: Double, counts: CIIssueCounts? = nil
    ) -> CIBuildAction {
        CIBuildAction(
            id: id, buildRunID: "run-1", name: name, actionType: type, startedDate: day, finishedDate: progress == .complete ? day.addingTimeInterval(seconds) : nil,
            executionProgress: progress, completionStatus: completion, isRequiredToPass: true, issueCounts: counts
        )
    }

    private static func issue(_ id: String, _ action: String, _ type: CIIssueType, _ message: String, _ path: String, _ line: Int, _ category: String = "Swift Compiler Error") -> CIIssue {
        CIIssue(id: id, buildActionID: action, type: type, message: message, category: category, file: CIFileLocation(path: path, lineNumber: line))
    }

    static func make(_ scenario: Case, directory: URL) async throws -> SheetRig {
        let sourceCommit = CISourceCommit(commitSha: "e04b7d1a3f9c21b8d7e6f5a4b3c2d1e0f9a8b7c6", message: "Corrige l’arrondi des caps magnétiques", authorName: "Guik", webURL: nil)
        var run = CIBuildRun(
            id: "run-1", productID: "p1", number: 411, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(372),
            executionProgress: .complete, completionStatus: .failed, startReason: "PULL_REQUEST_UPDATE", workflowID: "wf", workflowName: "Tests",
            sourceBranchOrTag: "main", sourceCommit: sourceCommit
        )
        var actions: [CIBuildAction] = []
        var extras = BuildExtras()
        var workflow = CIWorkflow(id: "wf", name: "Tests", testDestinationCounts: [1])
        workflow.actions = [CIWorkflowAction(name: "Test – iOS", actionType: .test)]

        switch scenario {
        case .failedTests:
            run.issueCounts = CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 3, warnings: 2)
            actions = [
                action("a1", "Build", .build, .succeeded, seconds: 121),
                action("a2", "Test – iOS", .test, .failed, seconds: 220, counts: CIIssueCounts(testFailures: 3)),
                action("a3", "Test – macOS", .test, .succeeded, seconds: 31, counts: CIIssueCounts(warnings: 2)),
            ]
            let device = CITestDeviceResult(deviceName: "iPhone 17", osVersion: "iOS 26", status: .failure, duration: 0.012)
            func test(_ id: String, _ name: String, _ status: CITestStatus, message: String? = nil, line: Int = 0) -> CITestResult {
                CITestResult(
                    id: id, buildActionID: "a2", className: "CompassHeadingTests", name: name, status: status, message: message,
                    file: message == nil ? nil : CIFileLocation(path: "/Volumes/workspace/repository/Tests/CompassHeadingTests.swift", lineNumber: line),
                    devices: [device]
                )
            }
            var results = [
                test("t1", "testRoundsToNearestDegree()", .failure, message: "XCTAssertEqual failed: (“271.5”) is not equal to (“272.0”)", line: 84),
                test("t2", "testWrapsAroundAt360()", .failure, message: "XCTAssertLessThan failed: (“360.4”) is not less than (“360.0”)", line: 97),
                CITestResult(
                    id: "t3", buildActionID: "a2", className: "DeclinationTests", name: "testEastIsPositive()", status: .failure, message: "XCTAssertTrue failed",
                    file: CIFileLocation(path: "/Volumes/workspace/repository/Tests/DeclinationTests.swift", lineNumber: 12), devices: [device]
                ),
            ]
            results += (0..<209).map { test("p\($0)", "testCase\($0)()", .success) }
            extras.testsByAction = ["a2": results, "a3": []]
            extras.issuesByAction = [
                "a1": [], "a2": [],
                "a3": [
                    issue("w1", "a3", .warning, "Variable ‘declination’ was never mutated; consider changing to ‘let’", "/Volumes/workspace/repository/Sources/Heading/CompassHeading.swift", 58, "Swift Compiler Warning"),
                    issue("w2", "a3", .warning, "Result of call to ‘normalize(_:)’ is unused", "/Volumes/workspace/repository/Sources/Heading/MagneticModel.swift", 132, "Swift Compiler Warning"),
                ],
            ]
            extras.artifactsByAction = [
                "a1": [CIArtifact(id: "f1", buildActionID: "a1", fileType: "LOG_BUNDLE", fileName: "Build logs.zip", fileSize: 3_000_000, downloadURL: nil)],
                "a2": [CIArtifact(id: "f2", buildActionID: "a2", fileType: "TEST_PRODUCTS", fileName: "TestProducts.zip", fileSize: 179_000_000, downloadURL: nil)],
            ]
        case .compileFailure:
            run = CIBuildRun(
                id: "run-1", productID: "p1", number: 57, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(108),
                executionProgress: .complete, completionStatus: .failed, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Default",
                sourceBranchOrTag: "main", issueCounts: CIIssueCounts(analyzerWarnings: 0, errors: 2, testFailures: 0, warnings: 3), sourceCommit: sourceCommit
            )
            actions = [action("a1", "Build", .build, .failed, seconds: 108, counts: CIIssueCounts(errors: 2, warnings: 3))]
            extras.issuesByAction = ["a1": [
                issue("e1", "a1", .error, "Cannot convert value of type ‘Double?’ to expected argument type ‘Double’", "/Volumes/workspace/repository/Menu/ProgressRing.swift", 42),
                issue("e2", "a1", .error, "Value of type ‘MenuBarModel’ has no member ‘runningBuilds’", "/Volumes/workspace/repository/StatusItemController.swift", 118),
                issue("w1", "a1", .warning, "Variable ‘fraction’ was never mutated; consider ‘let’", "/Volumes/workspace/repository/Menu/ProgressRing.swift", 37, "Swift Compiler Warning"),
                issue("w2", "a1", .warning, "Initialization of immutable value ‘oldBadge’ was never used", "/Volumes/workspace/repository/StatusItemController.swift", 96, "Swift Compiler Warning"),
                issue("w3", "a1", .warning, "Result of call to ‘schedule(after:)’ is unused", "/Volumes/workspace/repository/Sync/SyncSchedule.swift", 61, "Swift Compiler Warning"),
            ]]
            extras.testsByAction = [:]
            extras.artifactsByAction = ["a1": []]
        case .running:
            run = CIBuildRun(
                id: "run-1", productID: "p1", number: 412, createdDate: day, startedDate: day, finishedDate: nil, executionProgress: .running,
                completionStatus: nil, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Release", sourceBranchOrTag: "main", sourceCommit: sourceCommit
            )
            actions = [
                action("a1", "Build", .build, .succeeded, seconds: 170),
                action("a2", "Archive", .archive, nil, progress: .running, seconds: 0),
            ]
            workflow.actions = []
        case .delivered:
            run = CIBuildRun(
                id: "run-1", productID: "p1", number: 208, createdDate: day, startedDate: day, finishedDate: day.addingTimeInterval(935),
                executionProgress: .complete, completionStatus: .succeeded, startReason: "BRANCH_CHANGE", workflowID: "wf", workflowName: "Public archive",
                sourceBranchOrTag: "develop", issueCounts: CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 0, warnings: 6), sourceCommit: sourceCommit
            )
            actions = [
                action("a1", "Build", .build, .succeeded, seconds: 300, counts: CIIssueCounts(warnings: 6)),
                action("a2", "Archive", .archive, .succeeded, seconds: 635),
            ]
            workflow.actions = []
            extras.betaBuilds = [CIBetaBuild(id: "b1", version: "2.1 (208)", uploadedDate: day, processingState: "VALID")]
            extras.artifactsByAction = [
                "a2": [
                    CIArtifact(id: "f1", buildActionID: "a2", fileType: "ARCHIVE", fileName: "Hyrox.xcarchive.zip", fileSize: 148_000_000, downloadURL: nil),
                    CIArtifact(id: "f2", buildActionID: "a2", fileType: "APP", fileName: "Hyrox.ipa", fileSize: 31_000_000, downloadURL: nil),
                    CIArtifact(id: "f3", buildActionID: "a2", fileType: "LOG_BUNDLE", fileName: "Logs.zip", fileSize: 3_000_000, downloadURL: nil),
                ],
            ]
            extras.issuesByAction = ["a1": [issue("w1", "a1", .warning, "Variable ‘x’ was never mutated; consider ‘let’", "/Volumes/workspace/repository/A.swift", 3, "Swift Compiler Warning")], "a2": []]
        }
        if scenario != .running {
            extras.issuesComplete = true
            extras.testsComplete = true
            extras.artifactsComplete = true
        }

        let cache = BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json"))
        try await cache.save(BuildSnapshot(
            products: [CIProduct(id: "p1", name: "cart", productType: "APP", appID: "1", appName: "Cart", bundleID: nil)], runs: [run],
            actionsByRunID: ["run-1": actions], workflows: [workflow]
        ))
        let store = BuildStore(cacheStore: cache)
        await store.loadCacheIfNeeded()
        let client = AppStoreConnectClient(credentials: .sample(), transport: NoTransport())
        let detailsCache = BuildExtrasCache(directory: directory.appending(path: "details"))
        if run.executionProgress == .complete { await detailsCache.save(extras, runID: run.id) }
        let extrasStore = BuildExtrasStore(cache: detailsCache, client: { client })
        await extrasStore.loadCached(run)
        return SheetRig(run: run, store: store, extras: extrasStore, saver: ArtifactSaver(client: { client }))
    }

    func window(parts: BuildPartsState, width: CGFloat, height: CGFloat, dark: Bool) -> (NSWindow, NSView) {
        let root = BuildDetailView(
            run: run, buildStore: store, extrasStore: extras, artifactSaver: saver, teamID: nil, parts: parts
        )
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let size = CGSize(width: width, height: height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.frame = NSRect(origin: .zero, size: size)
        return (window, hosting)
    }

    static func png(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// The detail card of a build, drawn for real: what its lines show depends on the state of the card, not on the parts
/// opened and closed before (XCO-178: pills that were not selected lost their labels once another tab had been chosen).
@MainActor
@Suite(.serialized)
struct BuildPartsRenderTests {
    @Test(arguments: [false, true])
    func theLinesKeepTheirTextAfterAPartWasOpenedAndClosed(dark: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "parts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try await SheetRig.make(.compileFailure, directory: directory)
        let parts = BuildPartsState()
        let (window, view) = rig.window(parts: parts, width: 560, height: 900, dark: dark)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))

        let runID = rig.run.id
        for part in [BuildPart.actions, .problems, .artifacts, .actions, .artifacts, .problems] {
            let open = parts.isExpanded(part, runID: runID, byDefault: false)
            parts.setExpanded(!open, part: part, runID: runID)
            try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(900))

        let fresh = BuildPartsState()
        for part in BuildPart.allCases {
            fresh.setExpanded(parts.isExpanded(part, runID: runID, byDefault: false), part: part, runID: runID)
        }
        let (freshWindow, freshView) = rig.window(parts: fresh, width: 560, height: 900, dark: dark)
        defer { freshWindow.close() }
        try await Task.sleep(for: .milliseconds(900))

        // A window that is key draws its default button in the accent colour: both are captured while key.
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let seen = try #require(SheetRig.png(of: view))
        freshWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let expected = try #require(SheetRig.png(of: freshView))
        if seen != expected {
            Attachment.record(seen, named: "\(dark ? "dark" : "light")-seen.png")
            Attachment.record(expected, named: "\(dark ? "dark" : "light")-expected.png")
        }
        #expect(seen == expected, "the card after opening and closing parts (\(dark ? "dark" : "light")) differs from one drawn in that state from the start")
    }

    @Test func aPartAnotherScreenAsksForIsOpenedForThatBuildOnly() {
        let parts = BuildPartsState()
        #expect(!parts.isExpanded(.tests, runID: "a", byDefault: false))
        parts.show(.tests, ofRun: "a")
        #expect(parts.isExpanded(.tests, runID: "a", byDefault: false))
        #expect(!parts.isExpanded(.tests, runID: "b", byDefault: false))
        #expect(parts.request?.part == .tests)
        parts.setExpanded(false, part: .tests, runID: "a")
        #expect(!parts.isExpanded(.tests, runID: "a", byDefault: true), "the user's choice outweighs the default")
        parts.finish(DetailScrollTarget(id: BuildPart.tests, serial: parts.request?.serial ?? -1))
        #expect(parts.request == nil)
    }
}
