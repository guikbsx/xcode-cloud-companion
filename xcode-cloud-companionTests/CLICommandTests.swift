import Foundation
import Testing
@testable import XcodeCloudCompanion

struct CLICommandTests {
    private func report(_ query: CLIQuery, environment: CLIEnvironment? = nil) async throws -> CLIResponse {
        let environment = if let environment { environment } else { try await CLIFixture.environment() }
        return try await CLIQueryRunner(environment: environment).run(query)
    }

    private func failure(_ query: CLIQuery, environment: CLIEnvironment? = nil) async throws -> CLIFailure? {
        do {
            _ = try await report(query, environment: environment)
            return nil
        } catch let error as CLIFailure {
            return error
        }
    }

    private func builds(_ query: BuildsQuery) async throws -> [BuildOutput] {
        guard case .builds(let builds) = try await report(.builds(query)).report else { return [] }
        return builds
    }

    // MARK: - Status and usage

    @Test func statusGivesTheCycleAndWhatRuns() async throws {
        let response = try await report(.status)
        guard case .status(let status) = response.report else {
            Issue.record("not a status")
            return
        }
        let usage = try #require(status.usage)

        #expect(status.planConfigured && status.hint == nil)
        #expect(status.runningBuilds == 2 && status.appCount == 3)
        #expect(usage.planHours == 25 && usage.quotaMinutes == 1500)
        #expect(usage.billedMinutes == 15)
        // a44 24.25 + a42 4.5 + b10 9 + b9 7.5 + g7 15, the running and pending builds counting for nothing yet.
        #expect(abs(usage.estimatedMinutes - 60.25) < 0.11)
        #expect(abs(usage.usedMinutes - 75.25) < 0.11)
        #expect(abs(usage.remainingMinutes - 1424.75) < 0.11)
        #expect(usage.fractionUsed == 0.05)
        #expect(usage.cycleStart == CLIFixture.date("2026-10-01T00:00:00Z"))
        #expect(usage.resetDate == CLIFixture.date("2026-11-01T00:00:00Z"))
        #expect(usage.projectedMinutes != nil && usage.exhaustionDate == nil)
        #expect(usage.lastImport == CLIFixture.date("2026-10-09T07:00:00Z") && !usage.importIsStale)
        #expect(usage.measurement == UsageOutput.Measurement(isMeasuring: true, pendingBuilds: 1, measuredActions: 1, totalActions: 2, unmeasurableActions: 0))
        #expect(usage.note?.contains("still measuring 1 builds") == true)
        #expect(response.meta == CLIMeta(lastSuccessfulSync: CLIFixture.date("2026-10-10T09:55:00Z"), generatedAt: CLIFixture.now, cliVersion: "1.0", isEstimate: true, account: "Personal"))
    }

    @Test func withoutAPlanTheCycleIsLeftOut() async throws {
        let environment = try await CLIFixture.environment(plan: nil)
        let response = try await report(.status, environment: environment)
        guard case .status(let status) = response.report else { return }

        #expect(!status.planConfigured && status.usage == nil)
        #expect(status.hint?.contains("Settings › Usage") == true)
        #expect(status.runningBuilds == 2)
        #expect(!response.meta.isEstimate)

        guard case .usage(let usage) = try await report(.usage(.byApp), environment: environment).report else { return }
        #expect(!usage.planConfigured && usage.summary == nil && usage.byApp == nil)
    }

    @Test func usageBreaksTheCycleDown() async throws {
        guard case .usage(let summary) = try await report(.usage(.summary)).report,
              case .usage(let byApp) = try await report(.usage(.byApp)).report,
              case .usage(let byWorkflow) = try await report(.usage(.byWorkflow)).report,
              case .usage(let daily) = try await report(.usage(.daily)).report
        else { return }

        #expect(summary.summary?.billedMinutes == 15)
        #expect(summary.byApp == nil && summary.byWorkflow == nil && summary.daily == nil)
        #expect(summary.costliestBuild == UsageReportOutput.CostliestBuild(app: "Alpha", number: 44, reference: "Alpha#44", workflow: "CI", minutes: 24.3, isEstimated: true)
            || summary.costliestBuild?.minutes == 24.2)

        #expect(byApp.byApp?.map(\.app) == ["Alpha", "Beta", "Gamma Tools"])
        #expect(byApp.byApp?.first?.billedMinutes == 15)
        #expect(byApp.byApp?.last == UsageReportOutput.App(app: "Gamma Tools", billedMinutes: 0, estimatedMinutes: 15, totalMinutes: 15))

        let ci = try #require(byWorkflow.byWorkflow?.first)
        #expect(ci.app == "Alpha" && ci.workflow == "CI" && ci.buildCount == 4 && ci.billedMinutes == 15)
        #expect(byWorkflow.byWorkflow?.map(\.workflow) == ["CI", "Release", "Default"])

        #expect(daily.daily?.count == 30)
        #expect(daily.daily?.last?.day == "2026-10-10")
        #expect(daily.daily?.first { $0.day == "2026-10-08" }?.billedMinutes == 15)
        #expect(daily.daily?.first { $0.day == "2026-10-02" }?.estimatedMinutes == 15)
    }

    // MARK: - Apps and workflows

    @Test func appsCarryTheirLatestBuildAndCycle() async throws {
        guard case .apps(let apps) = try await report(.apps).report else { return }

        #expect(apps.map(\.name) == ["Alpha", "Beta", "Gamma Tools"])
        #expect(apps[0].id == "p-alpha" && apps[0].bundleID == "com.example.alpha" && apps[0].type == "APP")
        #expect(apps[0].latestBuild == BuildBrief(id: "run-a45", reference: "Alpha#45", number: 45, status: "running", createdDate: CLIFixture.date("2026-10-10T09:50:00Z"), finishedDate: nil))
        #expect(apps[0].runningBuilds == 1 && apps[1].runningBuilds == 0 && apps[2].runningBuilds == 1)
        #expect(apps[1].latestBuild?.status == "succeeded" && apps[2].latestBuild?.status == "pending")
        #expect(apps[0].cycle?.billedMinutes == 15)
        #expect(apps[1].cycle == MinutesOutput(billedMinutes: 0, estimatedMinutes: 16.5, totalMinutes: 16.5))
    }

    @Test func workflowsMergeWhatTheWindowRead() async throws {
        guard case .workflows(let all) = try await report(.workflows(app: nil)).report,
              case .workflows(let alpha) = try await report(.workflows(app: "com.example.ALPHA")).report
        else { return }

        #expect(all.map(\.name) == ["CI", "Release", "Default"])
        #expect(alpha.map(\.id) == ["w-ci"])
        let ci = alpha[0]
        #expect(ci.app == "Alpha" && ci.productID == "p-alpha" && ci.testDestinations == 2)
        #expect(ci.isEnabled == true && ci.description == "Runs on every pull request" && ci.xcodeVersion == "Xcode 27.1" && ci.repository == "example/alpha")
        #expect(ci.lastBuild?.reference == "Alpha#45")
        #expect(ci.cycle?.buildCount == 4 && ci.cycle?.billedMinutes == 15)
        #expect(all[1].isEnabled == nil && all[1].lastBuild?.reference == "Beta#10")
    }

    // MARK: - Builds

    @Test func buildsComeNewestFirstAndStopAtTheLimit() async throws {
        let recent = try await builds(BuildsQuery())

        #expect(recent.count == 10)
        #expect(recent.prefix(4).map(\.reference) == ["Gamma Tools#8", "Alpha#45", "Alpha#44", "Beta#10"])
        #expect(try await builds(BuildsQuery(limit: 100)).count == 12)
        #expect(try await builds(BuildsQuery(limit: 2)).map(\.id) == ["run-g8", "run-a45"])
    }

    @Test func buildsFilterByStateAppAndDate() async throws {
        #expect(try await builds(BuildsQuery(failed: true)).map(\.reference) == ["Alpha#44", "Beta#9", "Alpha#42"])
        #expect(try await builds(BuildsQuery(running: true)).map(\.reference) == ["Gamma Tools#8", "Alpha#45"])
        #expect(try await builds(BuildsQuery(failed: true, running: true)).count == 5)
        #expect(try await builds(BuildsQuery(app: "beta", limit: 100)).map(\.number) == [10, 9, 8, 7])
        #expect(try await builds(BuildsQuery(app: "com.example.gamma")).map(\.app) == ["Gamma Tools", "Gamma Tools"])
        #expect(try await builds(BuildsQuery(app: "p-alpha", failed: true)).map(\.number) == [44, 42])
        #expect(try await builds(BuildsQuery(limit: 100, since: CLIFixture.date("2026-10-09T00:00:00Z"))).map(\.reference) == ["Gamma Tools#8", "Alpha#45", "Alpha#44", "Beta#10"])
    }

    @Test func aBuildRowSaysWhereItCameFromAndWhatItCost() async throws {
        let rows = try await builds(BuildsQuery(app: "Alpha", limit: 100))
        let failed = try #require(rows.first { $0.number == 44 })
        let billed = try #require(rows.first { $0.number == 43 })
        let running = try #require(rows.first { $0.number == 45 })

        #expect(failed.status == "failed" && failed.executionProgress == "COMPLETE" && failed.completionStatus == "FAILED")
        #expect(failed.source == BuildOutput.Source(kind: "pullRequest", name: "fix/login", pullRequestNumber: 12, pullRequestTitle: "Fix login"))
        #expect(failed.commit?.shortSha == "01234567" && failed.commit?.author == "Ada")
        #expect(failed.issueCounts?.errors == 1 && failed.issueCounts?.testFailures == 2)
        #expect(failed.durationSeconds == 720 && failed.workflow == "CI" && failed.workflowID == "w-ci")
        #expect(failed.billedMinutes == nil && abs((failed.estimatedMinutes ?? 0) - 24.25) < 0.06)
        #expect(billed.billedMinutes == 15 && billed.estimatedMinutes == nil)
        #expect(billed.source == BuildOutput.Source(kind: "branchOrTag", name: "main"))
        #expect(running.status == "running" && running.finishedDate == nil && running.durationSeconds == 540)

        // Test results still to come: no minutes yet, rather than a wrong figure.
        let waiting = try #require(try await builds(BuildsQuery(app: "Beta", limit: 100)).first { $0.number == 8 })
        #expect(waiting.billedMinutes == nil && waiting.estimatedMinutes == nil)
    }

    // MARK: - One build

    @Test func aBuildShowsWhyItFailed() async throws {
        let response = try await report(.build(reference: "alpha#44", fetch: false))
        guard case .build(let detail) = response.report else { return }

        #expect(detail.build.id == "run-a44" && detail.detailsAvailable)
        #expect(detail.detailsLoaded == BuildDetailOutput.Loaded(issues: true, tests: true, artifacts: true))
        #expect(detail.actions.map(\.name) == ["Build - iOS", "Test - iOS"])
        #expect(detail.actions[1].status == "failed" && detail.actions[1].type == "TEST" && detail.actions[1].durationSeconds == 360)
        #expect(detail.actions[1].testDevices == [BuildDetailOutput.Device(deviceName: "iPhone 16", osVersion: "18.0", testCount: 20, failedCount: 2, seconds: 200)])
        #expect(detail.actions[0].testDevices == nil)

        // Errors and test failures first and always; warnings stop at fifty.
        #expect(detail.issues.count == 52 && detail.omittedWarnings == 10)
        #expect(detail.issues[0] == BuildDetailOutput.Issue(
            actionID: "a44-build", action: "Build - iOS", type: "ERROR", category: "Swift Compiler Error",
            message: "Cannot find 'LoginView' in scope", file: FileOutput(path: "Sources/Login.swift", line: 42)
        ))
        #expect(detail.issues[1].type == "TEST_FAILURE" && detail.issues[2].type == "WARNING")

        #expect(detail.failedTests.map(\.name) == ["testSignIn()"])
        #expect(detail.failedTests[0].devices == [BuildDetailOutput.TestDevice(deviceName: "iPhone 16", osVersion: "18.0", status: "FAILURE", durationSeconds: 1.5)])
        #expect(detail.testSummary == BuildDetailOutput.TestSummary(total: 3, failed: 1, skipped: 1, passed: 1))
        #expect(detail.artifacts == [BuildDetailOutput.Artifact(actionID: "a44-build", fileName: "Logs.zip", fileType: "LOG_BUNDLE", fileSize: 2_400_000)])
        #expect(detail.testFlightBuilds.map(\.version) == ["44"])
        #expect(detail.links.appStoreConnect.absoluteString == "https://appstoreconnect.apple.com/apps/111/ci/builds/run-a44/summary")
        #expect(detail.links.cumulus == "cumulus://build/run-a44")
        #expect(detail.hint == nil)
        #expect(!response.json.contains("token=secret") && !response.json.contains("downloadURL"))
    }

    @Test func aBuildNeverOpenedInTheAppSaysItsDetailsAreMissing() async throws {
        guard case .build(let finished) = try await report(.build(reference: "Beta#10", fetch: false)).report,
              case .build(let running) = try await report(.build(reference: "run-a45", fetch: false)).report
        else { return }

        #expect(!finished.detailsAvailable && finished.issues.isEmpty && finished.failedTests.isEmpty && finished.testSummary == nil)
        #expect(finished.actions.map(\.name) == ["Archive - iOS"])
        #expect(finished.hint?.contains("cumulus open Beta#10") == true)
        #expect(!running.detailsAvailable && running.actions.isEmpty)
        #expect(running.hint?.contains("still running") == true)
    }

    // MARK: - References and failures

    @Test func aBuildIsFoundByItsIdItsReferenceOrItsNumber() async throws {
        let snapshot = CLIFixture.snapshot

        #expect(try CLIReference.run("run-b9", in: snapshot).number == 9)
        #expect(try CLIReference.run("Beta#9", in: snapshot).id == "run-b9")
        #expect(try CLIReference.run("gamma tools#7", in: snapshot).id == "run-g7")
        #expect(try CLIReference.run("com.example.alpha#42", in: snapshot).id == "run-a42")
        #expect(try CLIReference.run("45", in: snapshot).id == "run-a45")
        #expect(try CLIReference.product("ALPHA", in: snapshot).id == "p-alpha")
    }

    @Test func whatCannotBeFoundSaysWhatExists() async throws {
        let missingApp = try #require(try await failure(.builds(BuildsQuery(app: "Delta"))))
        #expect(missingApp.code == .notFound && missingApp.code.exitCode == 5)
        #expect(missingApp.suggestions == ["Known app: Alpha", "Known app: Beta", "Known app: Gamma Tools"])

        let missingBuild = try #require(try await failure(.build(reference: "Alpha#999", fetch: false)))
        #expect(missingBuild.code == .notFound && missingBuild.message == "Alpha has no build 999 in the cache.")

        let sharedName = try #require(try await failure(.workflows(app: "suite")))
        #expect(sharedName.code == .ambiguous && sharedName.suggestions == ["Beta (com.example.beta)", "Gamma Tools (com.example.gamma)"])

        let sharedNumber = try #require(try await failure(.build(reference: "7", fetch: false)))
        #expect(sharedNumber.code == .ambiguous && Set(sharedNumber.suggestions) == ["Beta#7", "Gamma Tools#7"])

        #expect(try await failure(.build(reference: "what", fetch: false))?.code == .notFound)
    }

    @Test func withoutACacheEveryQuerySaysToOpenTheApp() async throws {
        let environment = try await CLIFixture.environment(snapshot: nil)

        for query in [CLIQuery.status, .apps, .builds(BuildsQuery()), .build(reference: "Alpha#1", fetch: false), .workflows(app: nil), .usage(.summary)] {
            let failure = try #require(try await failure(query, environment: environment))
            #expect(failure.code == .noCache && failure.code.exitCode == 3)
            #expect(failure.suggestions.first?.contains("API key") == true)
        }
    }

    // MARK: - Accounts

    private func appNames(_ arguments: [String], environment: CLIEnvironment) async throws -> (names: [String], meta: [String: Any]) {
        let (data, meta) = try CLIFixture.json(await CumulusCLI.run(arguments: arguments + ["--json"], environment: environment))
        return ((data as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted(), meta)
    }

    @Test func everyCommandAnswersForTheAccountOnScreenOrForTheOneNamed() async throws {
        let environment = try await CLIFixture.environmentWithTwoAccounts()

        let shown = try await appNames(["apps"], environment: environment)
        #expect(shown.names == ["Alpha", "Beta", "Gamma Tools"])
        #expect(shown.meta["account"] as? String == "Personal")

        let named = try await appNames(["apps", "--account", "work"], environment: environment)
        #expect(named.names == ["Delta"])
        #expect(named.meta["account"] as? String == "Work" && named.meta["lastSuccessfulSync"] as? String == "2026-10-10T09:00:00Z")

        // A build is looked for in one account: the other account's is not found by accident.
        #expect(await CumulusCLI.run(arguments: ["build", "Delta#1", "--cached"], environment: environment).exitCode == 5)
        #expect(await CumulusCLI.run(arguments: ["build", "Delta#1", "--cached", "--account=Work"], environment: environment).exitCode == 0)
        #expect(await CumulusCLI.run(arguments: ["builds", "--account", "work-1"], environment: environment).stdout.contains("Delta#1"))

        // What the app shows is what the command answers for.
        let switched = try await appNames(["apps"], environment: try await CLIFixture.environmentWithTwoAccounts(workSelected: true))
        #expect(switched.names == ["Delta"] && switched.meta["account"] as? String == "Work")
    }

    @Test func accountsListsThemAndSaysWhichOneIsShown() async throws {
        let environment = try await CLIFixture.environmentWithTwoAccounts()
        let (data, meta) = try CLIFixture.json(await CumulusCLI.run(arguments: ["accounts"], environment: environment))
        let rows = try #require(data as? [[String: Any]])

        // The keys are the contract agents read: a change here is a breaking change.
        #expect(rows.map { Set($0.keys) } == [["appCount", "lastSuccessfulSync", "name", "selected"], ["appCount", "lastSuccessfulSync", "name", "selected"]])
        #expect(rows.compactMap { $0["name"] as? String } == ["Personal", "Work"])
        #expect(rows.compactMap { $0["selected"] as? Bool } == [true, false])
        #expect(rows.compactMap { $0["appCount"] as? Int } == [3, 1])
        #expect(meta["account"] as? String == "Personal" && meta["lastSuccessfulSync"] as? String == "2026-10-10T09:55:00Z")

        let table = await CumulusCLI.run(arguments: ["accounts", "--table"], environment: environment)
        #expect(table.stdout.contains("ACCOUNT") && table.stdout.contains("Work"))
    }

    @Test func aTableNamesItsAccountOnlyWhenThereAreSeveral() async throws {
        let several = await CumulusCLI.run(arguments: ["status", "--table", "--account", "Work"], environment: try await CLIFixture.environmentWithTwoAccounts())
        #expect(several.stdout.contains("Account: Work\n"))

        let alone = await CumulusCLI.run(arguments: ["status", "--table"], environment: try await CLIFixture.environment())
        #expect(alone.exitCode == 0 && !alone.stdout.contains("Account:"))
    }

    @Test func anAccountThatIsNotFoundSaysWhichExist() async throws {
        let environment = try await CLIFixture.environmentWithTwoAccounts()

        let missing = await CumulusCLI.run(arguments: ["status", "--account", "Client", "--json"], environment: environment)
        #expect(missing.exitCode == 5 && missing.stdout.isEmpty)
        #expect(missing.stderr.contains("NOT_FOUND") && missing.stderr.contains("Known account: Personal") && missing.stderr.contains("Known account: Work"))

        // Two accounts may wear one name: the id tells them apart.
        try await CLIFixture.add(Account(id: "work-2", name: "work"), snapshot: BuildSnapshot(), to: environment)
        let ambiguous = await CumulusCLI.run(arguments: ["status", "--account", "Work", "--json"], environment: environment)
        #expect(ambiguous.exitCode == 5 && ambiguous.stderr.contains("AMBIGUOUS") && ambiguous.stderr.contains("work-2"))
        #expect(await CumulusCLI.run(arguments: ["status", "--account", "work-2"], environment: environment).exitCode == 0)

        #expect(await CumulusCLI.run(arguments: ["status", "--account"], environment: environment).exitCode == 2)
        #expect(await CumulusCLI.run(arguments: ["status", "--account", " "], environment: environment).exitCode == 2)
        #expect(await CumulusCLI.run(arguments: ["accounts", "--account", "Work"], environment: environment).exitCode == 2)
    }

    @Test func beforeTheAppEverRanThereIsNoAccountToAnswerFor() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "cumulus-cli-\(UUID().uuidString)")
        let environment = CLIEnvironment(version: "1.0", build: "7", directory: empty)

        for arguments in [["status"], ["accounts"], ["apps", "--account", "Work"], ["open", "Alpha#1"]] {
            let result = await CumulusCLI.run(arguments: arguments + ["--json"], environment: environment)
            #expect(result.exitCode == 3 && result.stderr.contains("NO_CACHE"), "\(arguments)")
        }
    }

    // MARK: - The command itself

    @Test func intoAPipeTheAnswerIsAJSONEnvelope() async throws {
        let environment = try await CLIFixture.environment()
        let result = await CumulusCLI.run(arguments: ["builds", "--limit", "1", "--app", "Alpha", "--failed"], environment: environment)
        let (data, meta) = try CLIFixture.json(result)
        let row = try #require((data as? [[String: Any]])?.first)

        #expect(result.exitCode == 0 && result.stderr.isEmpty)
        #expect(Set(meta.keys) == ["account", "appRunning", "cliVersion", "generatedAt", "isEstimate", "lastSuccessfulSync"])
        #expect(meta["account"] as? String == "Personal")
        #expect(meta["appRunning"] as? Bool == false)
        #expect(meta["lastSuccessfulSync"] as? String == "2026-10-10T09:55:00Z" && meta["generatedAt"] as? String == "2026-10-10T10:00:00Z")
        #expect(meta["isEstimate"] as? Bool == true && meta["cliVersion"] as? String == "1.0")
        // The keys are the contract agents read: a change here is a breaking change.
        #expect(Set(row.keys) == [
            "app", "commit", "completionStatus", "createdDate", "durationSeconds", "estimatedMinutes", "executionProgress", "finishedDate", "id",
            "issueCounts", "number", "productID", "reference", "source", "startReason", "startedDate", "status", "workflow", "workflowID",
        ])
        #expect(row["createdDate"] as? String == "2026-10-09T15:00:00Z")
        #expect(Set((row["source"] as? [String: Any] ?? [:]).keys) == ["kind", "name", "pullRequestNumber", "pullRequestTitle"])
        #expect(Set((row["commit"] as? [String: Any] ?? [:]).keys) == ["author", "message", "sha", "shortSha", "url"])
    }

    @Test func theContractOfEveryAnswerIsItsKeys() async throws {
        let environment = try await CLIFixture.environment()
        func keys(_ arguments: String...) async throws -> Set<String> {
            let (data, _) = try CLIFixture.json(await CumulusCLI.run(arguments: arguments, environment: environment))
            return Set(((data as? [String: Any]) ?? (data as? [[String: Any]])?.first ?? [:]).keys)
        }

        #expect(try await keys("status") == ["appCount", "planConfigured", "runningBuilds", "usage"])
        #expect(try await keys("apps") == ["bundleID", "cycle", "id", "latestBuild", "name", "runningBuilds", "storeName", "type"])
        #expect(try await keys("workflows", "--app", "Alpha") == [
            "app", "cycle", "description", "id", "isEnabled", "lastBuild", "name", "productID", "repository", "testDestinations", "xcodeVersion",
        ])
        #expect(try await keys("usage", "--daily") == ["costliestBuild", "daily", "planConfigured", "summary"])
        #expect(try await keys("build", "Alpha#44") == [
            "actions", "artifacts", "build", "detailsAvailable", "detailsLoaded", "failedTests", "issues", "links", "omittedWarnings",
            "testFlightBuilds", "testSummary",
        ])

        let (status, _) = try CLIFixture.json(await CumulusCLI.run(arguments: ["status"], environment: environment))
        let usage = try #require((status as? [String: Any])?["usage"] as? [String: Any])
        #expect(Set(usage.keys) == [
            "billedMinutes", "cycleStart", "estimatedBuildCount", "estimatedMinutes", "fractionUsed", "importIsStale", "lastImport", "measurement",
            "note", "planHours", "projectedMinutes", "quotaMinutes", "remainingMinutes", "resetDate", "usedMinutes",
        ])
        #expect(usage["resetDate"] as? String == "2026-11-01T00:00:00Z")
    }

    @Test func beforeTheFirstSyncTheMetaSaysNull() async throws {
        var snapshot = CLIFixture.snapshot
        snapshot.lastSuccessfulSync = nil
        let environment = try await CLIFixture.environment(snapshot: snapshot, plan: nil)
        let result = await CumulusCLI.run(arguments: ["apps"], environment: environment)
        let (_, meta) = try CLIFixture.json(result)

        #expect(meta["lastSuccessfulSync"] is NSNull)
        #expect(meta["isEstimate"] == nil)
    }

    @Test func failuresGoToStandardErrorWithTheirExitCode() async throws {
        let environment = try await CLIFixture.environment()
        let empty = try await CLIFixture.environment(snapshot: nil)

        let notFound = await CumulusCLI.run(arguments: ["build", "Alpha#999"], environment: environment)
        let error = try #require((try JSONSerialization.jsonObject(with: Data(notFound.stderr.utf8)) as? [String: Any])?["error"] as? [String: Any])
        #expect(notFound.exitCode == 5 && notFound.stdout.isEmpty)
        #expect(error["code"] as? String == "NOT_FOUND" && error["message"] as? String == "Alpha has no build 999 in the cache.")
        #expect((error["suggestions"] as? [String])?.count == 1)

        #expect(await CumulusCLI.run(arguments: ["build", "7"], environment: environment).exitCode == 5)
        #expect(await CumulusCLI.run(arguments: ["status"], environment: empty).exitCode == 3)
        #expect(await CumulusCLI.run(arguments: ["builds", "--limit", "0"], environment: environment).exitCode == 2)
        #expect(await CumulusCLI.run(arguments: ["deploy"], environment: environment).exitCode == 2)
        #expect(await CumulusCLI.run(arguments: ["help", "deploy"], environment: environment).exitCode == 2)

        var terminal = empty
        terminal.isTerminal = true
        let readable = await CumulusCLI.run(arguments: ["status"], environment: terminal)
        #expect(readable.stderr == "Cumulus has not synced any build yet.\n  Open the Cumulus app and add your App Store Connect API key in Settings.\n")
    }

    @Test func versionAndHelpNeedNoCache() async throws {
        let environment = try await CLIFixture.environment(snapshot: nil)

        #expect(await CumulusCLI.run(arguments: ["version"], environment: environment) == CLIResult(stdout: "cumulus 1.0 (7)\n"))
        let help = await CumulusCLI.run(arguments: [], environment: environment)
        #expect(help.exitCode == 0 && help.stdout.split(separator: "\n").count <= 30)
        for name in CLIParser.commandNames {
            #expect(help.stdout.contains("  \(name) "))
            let topic = await CumulusCLI.run(arguments: ["help", name], environment: environment)
            #expect(topic.exitCode == 0 && topic.stdout.contains("USAGE: cumulus \(name)") && topic.stdout.contains("EXAMPLE:"))
        }
        #expect(await CumulusCLI.run(arguments: ["builds", "--help"], environment: environment).stdout.contains("--since <when>"))
        #expect(await CumulusCLI.run(arguments: ["status", "--help"], environment: environment).stdout.contains("--account <name>"))
        #expect(!(await CumulusCLI.run(arguments: ["accounts", "--help"], environment: environment).stdout.contains("--account <name>")))
    }

    @Test func theCacheInfoReadsTheSharedFolder() async throws {
        let found = await CumulusCLI.run(arguments: ["version", "--verbose"], environment: try await CLIFixture.environment())
        #expect(found.stdout.contains("last sync: 2026-10-10T09:55:00Z") && found.stdout.contains("apps: 3") && found.stdout.contains("builds: 12"))

        let missing = await CumulusCLI.run(arguments: ["_cache-info"], environment: try await CLIFixture.environment(snapshot: nil))
        #expect(missing.stdout.contains("no cache yet"))
    }

    @Test func openHandsTheBuildToTheApp() async throws {
        var environment = try await CLIFixture.environment()
        environment.openURL = { $0.absoluteString == "cumulus://build/run-b9" }

        #expect(await CumulusCLI.run(arguments: ["open", "Beta#9"], environment: environment) == CLIResult())
        #expect(await CumulusCLI.run(arguments: ["open", "Beta#10"], environment: environment).exitCode == 1)
        #expect(await CumulusCLI.run(arguments: ["open", "Beta#99"], environment: environment).exitCode == 5)
    }

    @Test func fiveHundredBuildsAreListedWellUnderTheBudget() async throws {
        var snapshot = CLIFixture.snapshot
        for index in 0..<500 {
            let run = CLIFixture.run("bulk-\(index)", product: "p-beta", number: 1000 + index, created: "2026-09-01T00:00:00Z", workflow: ("w-release", "Release"))
            snapshot.runs.append(run)
            snapshot.actionsByRunID[run.id] = [
                CLIFixture.action("bulk-\(index)-archive", run: run, type: .archive, name: "Archive", minutes: 9),
                CLIFixture.action("bulk-\(index)-build", run: run, type: .build, name: "Build", minutes: 4),
            ]
        }
        let environment = try await CLIFixture.environment(snapshot: snapshot)
        let clock = ContinuousClock()

        var listed = 0
        let elapsed = try await clock.measure {
            listed = try await builds(BuildsQuery(limit: 100), environment: environment).count
        }

        #expect(listed == 100)
        #expect(elapsed < .milliseconds(200))
    }

    private func builds(_ query: BuildsQuery, environment: CLIEnvironment) async throws -> [BuildOutput] {
        guard case .builds(let builds) = try await report(.builds(query), environment: environment).report else { return [] }
        return builds
    }
}
