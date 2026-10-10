import Foundation
@testable import XcodeCloudCompanion

/// A small account for the command's tests: 3 apps, 12 builds, one build with its details, a usage export of one build.
/// It is written to a temporary folder by the app's own stores, so the command reads the files the app really leaves.
enum CLIFixture {
    static let now = date("2026-10-10T10:00:00Z")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    static func date(_ text: String) -> Date {
        (try? Date.ISO8601FormatStyle().parse(text)) ?? .distantPast
    }

    static let plan = UsagePlan(hours: 25, resetAnchor: date("2026-10-01T00:00:00Z"))

    static let products = [
        CIProduct(id: "p-alpha", name: "Alpha", productType: "APP", appID: "111", appName: "Alpha", bundleID: "com.example.alpha"),
        CIProduct(id: "p-beta", name: "Beta", productType: "APP", appID: "222", appName: "Suite", bundleID: "com.example.beta"),
        CIProduct(id: "p-gamma", name: "Gamma Tools", productType: "FRAMEWORK", appID: nil, appName: "Suite", bundleID: "com.example.gamma"),
    ]

    static let workflows = [
        CIWorkflow(id: "w-ci", name: "CI", testDestinationCounts: [2], productID: "p-alpha"),
        CIWorkflow(id: "w-release", name: "Release", testDestinationCounts: [], productID: "p-beta"),
        CIWorkflow(id: "w-default", name: "Default", testDestinationCounts: [1], productID: "p-gamma"),
    ]

    static func run(
        _ id: String, product: String, number: Int, created: String, minutes: Double? = 10,
        progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded,
        workflow: (id: String, name: String) = ("w-ci", "CI"), branch: String? = "main"
    ) -> CIBuildRun {
        let createdDate = date(created)
        return CIBuildRun(
            id: id, productID: product, number: number, createdDate: createdDate,
            startedDate: progress == .pending ? nil : createdDate.addingTimeInterval(60),
            finishedDate: progress == .complete ? minutes.map { createdDate.addingTimeInterval(60 + $0 * 60) } : nil,
            executionProgress: progress, completionStatus: progress == .complete ? status : nil,
            startReason: "GIT_REF_CHANGE", workflowID: workflow.id, workflowName: workflow.name, sourceBranchOrTag: branch
        )
    }

    static func action(
        _ id: String, run: CIBuildRun, type: CIActionType, name: String, minutes: Double,
        status: CICompletionStatus = .succeeded, issues: CIIssueCounts? = nil
    ) -> CIBuildAction {
        let started = run.startedDate ?? now
        return CIBuildAction(
            id: id, buildRunID: run.id, name: name, actionType: type, startedDate: started, finishedDate: started.addingTimeInterval(minutes * 60),
            executionProgress: .complete, completionStatus: status, isRequiredToPass: true, issueCounts: issues
        )
    }

    static var snapshot: BuildSnapshot {
        var failed = run("run-a44", product: "p-alpha", number: 44, created: "2026-10-09T15:00:00Z", minutes: 12, status: .failed, branch: "fix/login")
        failed.isPullRequestBuild = true
        failed.pullRequestNumber = 12
        failed.pullRequestTitle = "Fix login"
        failed.issueCounts = CIIssueCounts(analyzerWarnings: 0, errors: 1, testFailures: 2, warnings: 60)
        failed.sourceCommit = CISourceCommit(
            commitSha: "0123456789abcdef0123456789abcdef01234567", message: "Fix the login screen", authorName: "Ada",
            webURL: URL(string: "https://example.com/commit/0123456789abcdef")
        )
        let billed = run("run-a43", product: "p-alpha", number: 43, created: "2026-10-08T09:00:00Z")
        let waiting = run("run-b8", product: "p-beta", number: 8, created: "2026-10-03T09:00:00Z", workflow: ("w-release", "Release"), branch: "v1.1")
        let runs = [
            run("run-a45", product: "p-alpha", number: 45, created: "2026-10-10T09:50:00Z", progress: .running),
            failed,
            billed,
            run("run-a42", product: "p-alpha", number: 42, created: "2026-10-05T09:00:00Z", minutes: 3, status: .errored),
            run("run-a41", product: "p-alpha", number: 41, created: "2026-09-28T09:00:00Z"),
            run("run-a40", product: "p-alpha", number: 40, created: "2026-09-20T09:00:00Z", minutes: 1, status: .canceled),
            run("run-b10", product: "p-beta", number: 10, created: "2026-10-09T08:00:00Z", minutes: 20, workflow: ("w-release", "Release"), branch: "v1.2"),
            run("run-b9", product: "p-beta", number: 9, created: "2026-10-07T08:00:00Z", minutes: 5, status: .failed, workflow: ("w-release", "Release"), branch: "v1.2"),
            waiting,
            run("run-b7", product: "p-beta", number: 7, created: "2026-09-25T08:00:00Z", workflow: ("w-release", "Release"), branch: "v1.0"),
            run("run-g8", product: "p-gamma", number: 8, created: "2026-10-10T09:59:00Z", progress: .pending, workflow: ("w-default", "Default")),
            run("run-g7", product: "p-gamma", number: 7, created: "2026-10-02T09:00:00Z", workflow: ("w-default", "Default")),
        ]
        var actions: [String: [CIBuildAction]] = [:]
        for run in runs where run.executionProgress == .complete {
            let minutes = (run.finishedDate ?? now).timeIntervalSince(run.startedDate ?? now) / 60
            actions[run.id] = [action("\(run.id)-archive", run: run, type: .archive, name: "Archive - iOS", minutes: minutes, status: run.completionStatus ?? .succeeded)]
        }
        actions[failed.id] = [
            action("a44-build", run: failed, type: .build, name: "Build - iOS", minutes: 5, issues: CIIssueCounts(errors: 1, warnings: 60)),
            action("a44-test", run: failed, type: .test, name: "Test - iOS", minutes: 6, status: .failed, issues: CIIssueCounts(testFailures: 2)),
        ]
        actions[waiting.id] = [
            action("b8-archive", run: waiting, type: .archive, name: "Archive - iOS", minutes: 6),
            action("b8-test", run: waiting, type: .test, name: "Test - iOS", minutes: 4),
        ]
        return BuildSnapshot(
            products: products, runs: runs, actionsByRunID: actions,
            testDevicesByActionID: ["a44-test": [CITestDeviceRun(deviceName: "iPhone 16", osVersion: "18.0", testCount: 20, failedCount: 2, totalSeconds: 200)]],
            workflows: workflows, lastSuccessfulSync: date("2026-10-10T09:55:00Z")
        )
    }

    static var ledger: UsageLedger {
        var ledger = UsageLedger()
        ledger.merge(
            UsageExport(
                builds: [BilledBuild(product: "Alpha", buildNumber: 43, workflow: "CI", startedAt: date("2026-10-08T09:01:00Z"), minutes: 15)],
                coverage: DateInterval(start: date("2026-10-01T00:00:00Z"), end: date("2026-10-09T00:00:00Z"))
            ),
            fileName: "usage_2026-10-01_2026-10-08.csv", modifiedAt: date("2026-10-09T07:00:00Z"), importedAt: date("2026-10-09T07:00:00Z")
        )
        return ledger
    }

    static var extras: BuildExtras {
        let warnings = (1...60).map { (index: Int) in
            CIIssue(
                id: "w\(index)", buildActionID: "a44-build", type: .warning, message: "Unused variable \(index)", category: "Swift",
                file: CIFileLocation(path: "Sources/File\(index).swift", lineNumber: index)
            )
        }
        return BuildExtras(
            betaBuilds: [CIBetaBuild(id: "beta-1", version: "44", uploadedDate: date("2026-10-09T15:20:00Z"), processingState: "VALID")],
            issuesByAction: [
                "a44-build": warnings + [
                    CIIssue(id: "e1", buildActionID: "a44-build", type: .error, message: "Cannot find 'LoginView' in scope", category: "Swift Compiler Error", file: CIFileLocation(path: "Sources/Login.swift", lineNumber: 42)),
                ],
                "a44-test": [CIIssue(id: "t1", buildActionID: "a44-test", type: .testFailure, message: "XCTAssertEqual failed", category: nil, file: nil)],
            ],
            testsByAction: [
                "a44-test": [
                    CITestResult(
                        id: "test-1", buildActionID: "a44-test", className: "LoginTests", name: "testSignIn()", status: .failure,
                        message: "XCTAssertEqual failed: (\"a\") is not equal to (\"b\")", file: CIFileLocation(path: "Tests/LoginTests.swift", lineNumber: 12),
                        devices: [CITestDeviceResult(deviceName: "iPhone 16", osVersion: "18.0", status: .failure, duration: 1.5)]
                    ),
                    CITestResult(id: "test-2", buildActionID: "a44-test", className: "LoginTests", name: "testSignOut()", status: .success, message: nil, file: nil, devices: []),
                    CITestResult(id: "test-3", buildActionID: "a44-test", className: "LoginTests", name: "testLater()", status: .skipped, message: nil, file: nil, devices: []),
                ],
            ],
            artifactsByAction: [
                "a44-build": [
                    CIArtifact(id: "art-1", buildActionID: "a44-build", fileType: "LOG_BUNDLE", fileName: "Logs.zip", fileSize: 2_400_000, downloadURL: URL(string: "https://example.com/signed?token=secret")),
                ],
            ],
            issuesComplete: true, testsComplete: true, artifactsComplete: true
        )
    }

    /// Writes the account to a new temporary folder and returns an environment that reads it.
    static func environment(
        snapshot: BuildSnapshot? = CLIFixture.snapshot, plan: UsagePlan? = CLIFixture.plan, withDetails: Bool = true,
        isTerminal: Bool = false, width: Int = 100
    ) async throws -> CLIEnvironment {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cumulus-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let snapshot {
            try await BuildCacheStore(fileURL: directory.appending(path: "BuildCache.json")).save(snapshot)
            try await UsageLedgerStore(fileURL: directory.appending(path: "UsageLedger.json")).save(ledger)
        }
        await SharedPlanStore(fileURL: directory.appending(path: "UsagePlan.json")).save(plan)
        if withDetails {
            await BuildExtrasCache(directory: directory.appending(path: "BuildDetails")).save(extras, runID: "run-a44")
            var detailed = workflows[0]
            detailed.isEnabled = true
            detailed.description = "Runs on every pull request"
            detailed.xcodeVersionName = "Xcode 27.1"
            detailed.repositoryName = "example/alpha"
            await WorkflowDetailsCache(directory: directory.appending(path: "WorkflowDetails"))
                .save(WorkflowDetailsFile(fetchedAt: now, workflows: [detailed]), productID: "p-alpha")
        }
        return CLIEnvironment(version: "1.0", build: "7", directory: directory, now: { now }, calendar: calendar, isTerminal: isTerminal, terminalWidth: width)
    }

    /// The `data` and `meta` of a JSON answer.
    static func json(_ result: CLIResult) throws -> (data: Any, meta: [String: Any]) {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] ?? [:]
        return (object["data"] ?? NSNull(), object["meta"] as? [String: Any] ?? [:])
    }
}
