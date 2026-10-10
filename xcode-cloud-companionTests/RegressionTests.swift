import Foundation
import Testing
@testable import XcodeCloudCompanion

private let day = Date(timeIntervalSince1970: 1_791_547_200) // 2026-10-09 12:00 UTC

private func run(
    _ number: Int, status: CICompletionStatus? = .succeeded, workflow: String? = "w1", branch: String? = "main", product: String = "p1",
    sha: String? = nil, commitURL: String? = nil, progress: CIExecutionProgress = .complete
) -> CIBuildRun {
    CIBuildRun(
        id: "run-\(number)", productID: product, number: number, createdDate: day.addingTimeInterval(Double(number) * 3600), startedDate: nil,
        finishedDate: nil, executionProgress: progress, completionStatus: status, startReason: nil, workflowID: workflow, workflowName: "CI",
        sourceBranchOrTag: branch,
        sourceCommit: sha.map { CISourceCommit(commitSha: $0, message: nil, authorName: nil, webURL: commitURL.flatMap(URL.init(string:))) }
    )
}

private func action(_ id: String, run number: Int, name: String = "Test - iOS", type: CIActionType = .test) -> CIBuildAction {
    CIBuildAction(
        id: id, buildRunID: "run-\(number)", name: name, actionType: type, startedDate: day, finishedDate: day, executionProgress: .complete,
        completionStatus: .succeeded, isRequiredToPass: true
    )
}

private func test(_ name: String, _ status: CITestStatus, class className: String = "CartTests", action: String, message: String? = nil) -> CITestResult {
    CITestResult(
        id: "\(action)-\(className)-\(name)", buildActionID: action, className: className, name: name, status: status, message: message,
        file: CIFileLocation(path: "/src/\(className).swift", lineNumber: 12), devices: []
    )
}

private func issue(_ message: String, _ type: CIIssueType = .error, action: String, path: String = "/src/Cart.swift", line: Int = 3) -> CIIssue {
    CIIssue(id: "\(action)-\(message)-\(line)", buildActionID: action, type: type, message: message, category: nil, file: CIFileLocation(path: path, lineNumber: line))
}

private func extras(tests: [String: [CITestResult]] = [:], issues: [String: [CIIssue]] = [:], complete: Bool = true) -> BuildExtras {
    BuildExtras(issuesByAction: issues, testsByAction: tests, issuesComplete: complete, testsComplete: complete)
}

struct RegressionReferenceTests {
    @Test func theReferenceIsTheLastSuccessfulBuildOfTheWorkflowBeforeThisOne() {
        let failed = run(10, status: .failed)
        let snapshot = BuildSnapshot(runs: [
            run(12), failed, run(9, status: .failed), run(8), run(7), run(6, workflow: "other"), run(5, product: "p2"),
            run(4, status: nil, progress: .running),
        ])

        #expect(RegressionReport.reference(for: failed, in: snapshot)?.number == 8)
    }

    @Test func theSameBranchComesFirstThenAnyBranch() {
        let failed = run(10, status: .failed, branch: "feature")
        let snapshot = BuildSnapshot(runs: [failed, run(9, branch: "main"), run(8, branch: "feature"), run(7, branch: "feature")])

        #expect(RegressionReport.reference(for: failed, in: snapshot)?.number == 8)
        #expect(RegressionReport.reference(for: run(10, status: .failed, branch: "lonely"), in: snapshot)?.number == 9)
        #expect(RegressionReport.reference(for: run(10, status: .failed, branch: nil), in: snapshot)?.number == 9)
    }

    @Test func withoutAnEarlierSuccessThereIsNoReference() {
        let failed = run(10, status: .failed)

        #expect(RegressionReport.reference(for: failed, in: BuildSnapshot(runs: [failed, run(11), run(9, status: .errored)])) == nil)
        #expect(RegressionReport.reference(for: run(10, status: .failed, workflow: nil), in: BuildSnapshot(runs: [run(9)])) == nil)
    }
}

struct RegressionReportTests {
    private let actions = [action("build-new", run: 10, name: "Build - iOS", type: .build), action("test-new", run: 10)]
    private let referenceActions = [action("build-old", run: 8, name: "Build - iOS", type: .build), action("test-old", run: 8)]

    private func report(now: BuildExtras, before: BuildExtras) -> RegressionReport {
        RegressionReport(actions: actions, extras: now, referenceActions: referenceActions, referenceExtras: before)
    }

    @Test func aTestThatPassedBeforeAndFailsNowIsBroken() {
        let report = report(
            now: extras(tests: ["test-new": [test("testTotal", .failure, action: "test-new", message: "XCTAssertEqual failed"), test("testEmpty", .success, action: "test-new")]]),
            before: extras(tests: ["test-old": [test("testTotal", .success, action: "test-old"), test("testEmpty", .success, action: "test-old")]])
        )

        #expect(report.brokenTests.map(\.name) == ["testTotal"])
        #expect(report.brokenTests.first?.className == "CartTests")
        #expect(report.brokenTests.first?.actionName == "Test - iOS")
        #expect(report.brokenTests.first?.message == "XCTAssertEqual failed")
        #expect(report.brokenTests.first?.location == "CartTests.swift:12")
        #expect(report.persistingTests.isEmpty && report.newFailingTests.isEmpty)
        #expect(!report.isEmpty)
    }

    @Test func aTestThatAlreadyFailedIsSetApart() {
        let report = report(
            now: extras(tests: ["test-new": [test("testFlaky", .mixed, action: "test-new"), test("testTotal", .failure, action: "test-new")]]),
            before: extras(tests: ["test-old": [test("testFlaky", .failure, action: "test-old"), test("testTotal", .skipped, action: "test-old")]])
        )

        #expect(report.persistingTests.map(\.name) == ["testFlaky"])
        #expect(report.brokenTests.map(\.name) == ["testTotal"])
    }

    @Test func aTestAbsentFromTheReferenceIsNewNotBroken() {
        let report = report(
            now: extras(tests: ["test-new": [test("testCoupon", .failure, action: "test-new"), test("testTotal", .failure, class: "OrderTests", action: "test-new")]]),
            before: extras(tests: ["test-old": [test("testTotal", .success, action: "test-old")]])
        )

        #expect(report.newFailingTests.map(\.id).count == 2)
        #expect(report.newFailingTests.map(\.name) == ["testCoupon", "testTotal"])
        #expect(report.brokenTests.isEmpty)
    }

    @Test func testsAreMatchedWithinActionsOfTheSameName() {
        let macAction = action("test-mac", run: 10, name: "Test - macOS")
        let report = RegressionReport(
            actions: actions + [macAction],
            extras: extras(tests: ["test-mac": [test("testTotal", .failure, action: "test-mac")], "test-new": [test("testTotal", .failure, action: "test-new")]]),
            referenceActions: referenceActions, referenceExtras: extras(tests: ["test-old": [test("testTotal", .success, action: "test-old")]])
        )

        #expect(report.brokenTests.map(\.actionName) == ["Test - iOS"])
        #expect(report.newFailingTests.map(\.actionName) == ["Test - macOS"])
    }

    @Test func onlyIssuesTheReferenceDidNotHaveAreNew() {
        let report = report(
            now: extras(issues: ["build-new": [
                issue("Cannot find 'total' in scope", action: "build-new"),
                issue("Variable was never used", .warning, action: "build-new", line: 40),
                issue("XCTAssertEqual failed", .testFailure, action: "build-new"),
                issue("Cannot find 'total' in scope", action: "build-new", line: 9),
            ]]),
            before: extras(issues: ["build-old": [issue("Variable was never used", .warning, action: "build-old", line: 12)]])
        )

        #expect(report.newIssues.map(\.message) == ["Cannot find 'total' in scope"])
        #expect(report.newIssues.first?.type == .error)
        #expect(report.newIssues.first?.location == "Cart.swift:3")
    }

    @Test func nothingIsComparedBeforeBothBuildsAreFullyLoaded() {
        #expect(RegressionReport.isReady(extras: extras(), referenceExtras: extras()))
        #expect(!RegressionReport.isReady(extras: extras(), referenceExtras: nil))
        #expect(!RegressionReport.isReady(extras: extras(complete: false), referenceExtras: extras()))
        #expect(report(now: extras(), before: extras()).isEmpty)
    }

    @Test func commitsShowOnlyWhenBothAreKnown() throws {
        let commitURL = "https://github.com/guik/app/commit/2222222222222222222222222222222222222222"
        let old = run(8, sha: "1111111111111111111111111111111111111111")
        let new = run(10, status: .failed, sha: "2222222222222222222222222222222222222222", commitURL: commitURL)

        let range = try #require(CommitRange(reference: old, run: new))
        #expect(range.from == "11111111" && range.to == "22222222")
        #expect(range.isComparison)
        #expect(range.url?.absoluteString == "https://github.com/guik/app/compare/1111111111111111111111111111111111111111...2222222222222222222222222222222222222222")

        #expect(CommitRange(reference: run(8), run: new) == nil)
        #expect(CommitRange(reference: old, run: run(10, status: .failed)) == nil)
    }

    @Test func anotherGitHostKeepsItsOwnCommitLink() throws {
        let commitURL = "https://gitlab.com/guik/app/-/commit/2222222222222222222222222222222222222222"
        let range = try #require(CommitRange(
            reference: run(8, sha: "1111111111111111111111111111111111111111"),
            run: run(10, status: .failed, sha: "2222222222222222222222222222222222222222", commitURL: commitURL)
        ))

        #expect(!range.isComparison)
        #expect(range.url?.absoluteString == commitURL)
        #expect(CommitRange.gitHubComparison(commitURL: URL(string: "https://github.com/guik/app/commit/abc"), from: "abc", to: "abc") == nil)
        #expect(CommitRange.gitHubComparison(commitURL: URL(string: "https://github.com/guik/app/commit/abc"), from: "a/../b", to: "abc") == nil)
    }
}

@MainActor
struct RegressionCacheTests {
    @Test func whatIsOnDiskComesBackWithoutAnyRequest() async {
        let cache = BuildExtrasCache(directory: FileManager.default.temporaryDirectory.appending(path: "BuildDetails-\(UUID().uuidString)"))
        let stored = extras(tests: ["test-old": [test("testTotal", .success, action: "test-old")]])
        await cache.save(stored, runID: "run-8")
        let store = BuildExtrasStore(cache: cache, client: {
            Issue.record("No request is expected")
            return nil
        })

        await store.loadCached(run(8))
        await store.loadCached(run(10, status: nil, progress: .running))

        #expect(store.extras(for: "run-8") == stored)
        #expect(store.extras(for: "run-10") == nil)
    }
}
