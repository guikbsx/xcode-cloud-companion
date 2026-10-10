import Foundation
import Testing
@testable import XcodeCloudCompanion

struct DetailClientTests {
    private func client(_ fixture: String, status: Int = 200, headers: [String: String] = [:]) -> (AppStoreConnectClient, MockTransport) {
        let transport = MockTransport { _ in
            MockTransport.Reply(status: status, body: (try? Fixture.data(fixture)) ?? Data(), headers: headers)
        }
        return (AppStoreConnectClient(credentials: .sample(), transport: transport), transport)
    }

    @Test func buildRunsCarryCountersCommitAndPullRequest() async throws {
        let (client, _) = client("ciBuildRuns-details")

        let runs = try await client.buildRuns(productID: "p", maxPages: 1)

        let run = try #require(runs.first)
        #expect(run.issueCounts == CIIssueCounts(analyzerWarnings: 0, errors: 1, testFailures: 3, warnings: 2))
        #expect(run.issueCounts?.total == 6)
        #expect(run.sourceCommit?.commitSha?.hasPrefix("d4c3b2a1") == true)
        #expect(run.sourceCommit?.shortSha == "d4c3b2a1")
        #expect(run.sourceCommit?.authorName == "Guillaume Bisiaux")
        #expect(run.sourceCommit?.webURL?.host() == "github.com")
        #expect(run.isPullRequestBuild == true)
        #expect(run.pullRequestNumber == 7)
        #expect(run.pullRequestTitle == "Widget : vue Semaine")
        #expect(run.sourceBranchOrTag == "feature/widget")
    }

    @Test func aRunWithoutTheNewFieldsDecodesAsNil() async throws {
        let (client, _) = client("ciBuildRuns-details")

        let run = try #require(try await client.buildRuns(productID: "p", maxPages: 1).last)

        #expect(run.cancelReason == "AUTOMATICALLY_BY_NEWER_BUILD")
        #expect(run.issueCounts == nil)
        #expect(run.sourceCommit == nil)
        #expect(run.pullRequestNumber == nil)
    }

    @Test func aCacheWrittenBeforeTheNewFieldsStillLoads() throws {
        let old = #"{"id":"r","productID":"p","number":3,"executionProgress":"COMPLETE","completionStatus":"SUCCEEDED"}"#

        let run = try JSONDecoder.appStoreConnect.decode(CIBuildRun.self, from: Data(old.utf8))

        #expect(run.number == 3)
        #expect(run.sourceCommit == nil)
        #expect(run.issueCounts == nil)
    }

    @Test func workflowDetailsIncludeVersionsRepositoryAndStartConditions() async throws {
        let (client, transport) = client("ciWorkflowDetails")

        let workflow = try #require(try await client.workflowDetails(productID: "p").first)

        let request = try #require(await transport.requests.first)
        #expect(request.queryValue("include") == "xcodeVersion,macOsVersion,repository")
        #expect(workflow.name == "Public archive (with test)")
        #expect(workflow.isEnabled == true)
        #expect(workflow.isLockedForEditing == false)
        #expect(workflow.clean == false)
        #expect(workflow.containerFilePath == "App.xcodeproj")
        #expect(workflow.lastModifiedDate != nil)
        #expect(workflow.xcodeVersionName == "Xcode 27.0")
        #expect(workflow.macOSVersionName == "macOS Tahoe (27.0)")
        #expect(workflow.repositoryName == "guikbsx/realmotivation")
        #expect(workflow.testDestinationCounts == [2])
        #expect(workflow.actions.map(\.actionType) == [.build, .test, .archive])
        #expect(workflow.actions[0].platform == .iOS)
        #expect(workflow.actions[2].buildDistributionAudience == "APP_STORE_ELIGIBLE")
        let conditions = try #require(workflow.startConditions)
        #expect(conditions.branches == CIPatterns(isAllMatch: false, patterns: ["develop", "release/"]))
        #expect(conditions.scheduleFrequency == .weekly)
        #expect(conditions.filesRule == .doNotStartIfAllFilesMatch)
        #expect(conditions.autoCancel == true)
        #expect(conditions.allowsManualStart)
        #expect(conditions.tags == nil)
    }

    @Test func issuesAreTypedAndUnknownKindsSurvive() async throws {
        let (client, transport) = client("ciIssues-sample")

        let issues = try await client.issues(buildActionID: "action-1")

        #expect(await transport.requests.first?.url?.path() == "/v1/ciBuildActions/action-1/issues")
        #expect(issues.map(\.type) == [.error, .testFailure, .unknown("SOMETHING_NEW")])
        #expect(issues[0].file == CIFileLocation(path: "Sources/App/Sync.swift", lineNumber: 42))
        #expect(issues.allSatisfy { $0.buildActionID == "action-1" })
    }

    @Test func testResultsKeepTheMessageTheFileAndEachDevice() async throws {
        let (client, _) = client("ciTests-sample")

        let results = try await client.testResults(buildActionID: "action-1")

        #expect(results.map(\.status) == [.failure, .mixed, .expectedFailure])
        #expect(results.map(\.status.isFailure) == [true, true, false])
        let first = results[0]
        #expect(first.className == "SyncTests")
        #expect(first.message == "XCTAssertEqual failed")
        #expect(first.file?.lineNumber == 18)
        #expect(first.devices.map(\.deviceName) == ["iPhone 17 Pro", "iPad Pro 13"])
        #expect(first.devices.map(\.status) == [.failure, .success])
        #expect(abs((first.duration ?? 0) - 2.6) < 0.0001)
        #expect(results[2].duration == nil)
    }

    @Test func artifactsListWithoutAddressesAndOneIsAskedWithItsFreshAddress() async throws {
        let (listClient, listTransport) = client("ciArtifacts-sample")
        let artifacts = try await listClient.artifacts(buildActionID: "action-1")
        #expect(artifacts.map(\.fileType) == ["LOG_BUNDLE", "RESULT_BUNDLE"])
        #expect(await listTransport.requests.first?.queryValue("fields[ciArtifacts]") == "fileType,fileName,fileSize")
        #expect(artifacts.allSatisfy { $0.downloadURL == nil })

        let (oneClient, oneTransport) = client("ciArtifact-sample")
        let artifact = try await oneClient.artifact(id: "art-1", buildActionID: "action-1")
        #expect(await oneTransport.requests.first?.url?.path() == "/v1/ciArtifacts/art-1")
        #expect(artifact.downloadURL?.host() == "example.icloud-content.com")
        #expect(artifact.fileSize == 2048)
    }

    @Test func betaBuildsOfARunAreDecoded() async throws {
        let (client, _) = client("ciBuilds-sample")

        let builds = try await client.betaBuilds(buildRunID: "run-1")

        #expect(builds == [CIBetaBuild(id: "beta-1", version: "390", uploadedDate: builds.first?.uploadedDate, processingState: "VALID")])
        #expect(builds.first?.uploadedDate != nil)
    }

    @Test func theHourlyBudgetIsReadFromEveryResponse() async throws {
        let (client, _) = client("ciProducts", headers: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:500;"])
        #expect(await client.rateLimit() == nil)

        _ = try await client.products()

        let limit = try #require(await client.rateLimit())
        #expect(limit == RateLimit(limit: 3500, remaining: 500))
        #expect(abs(limit.fractionRemaining - 500.0 / 3500.0) < 0.0001)
    }

    @Test(arguments: [nil, "", "garbage", "user-hour-lim:3500;", "user-hour-lim:abc;user-hour-rem:1;"])
    func aBrokenRateLimitHeaderIsIgnored(header: String?) {
        #expect(RateLimit(header: header) == nil)
    }

    @Test func aRefusalPointsAtTheFieldAtFault() async {
        let body = #"{"errors":[{"status":"422","code":"ENTITY_ERROR","title":"Unprocessable","detail":"Bad branch","source":{"pointer":"/data/relationships/sourceBranchOrTag"}}]}"#
        let transport = MockTransport { _ in MockTransport.Reply(status: 422, body: Data(body.utf8)) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect(throws: AppStoreConnectError.rejected(
            status: 422, code: "ENTITY_ERROR", title: "Unprocessable", detail: "Bad branch", pointer: "/data/relationships/sourceBranchOrTag"
        )) {
            try await client.products()
        }
    }

    @Test func aMissingAgreementHasItsOwnMessage() {
        let forbidden = AppStoreConnectError.forbidden(code: "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED", detail: nil)
        let role = AppStoreConnectError.forbidden(code: "FORBIDDEN_ERROR", detail: nil)

        #expect(forbidden.message.contains("agreement"))
        #expect(role.message.contains("role"))
        #expect(forbidden.message != role.message)
    }
}
