import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

// MARK: - The command line

struct TestFlightCommandParsingTests {
    @Test func theThreeFormsAreParsed() throws {
        #expect(try CLIParser.parse(["testflight", "Alpha#43"]).command == .query(.testFlight(reference: "Alpha#43", fetch: true)))
        #expect(try CLIParser.parse(["testflight", "--cached", "Alpha#43", "--account", "Work"]).command == .query(.testFlight(reference: "Alpha#43", fetch: false)))
        #expect(try CLIParser.parse(["testflight", "--account", "Work", "Alpha#43"]).account == "Work")

        let give = try CLIParser.parse([
            "testflight", "give", "Alpha#43", "--group", "QA", "--group=Beta", "--remove", "Friends", "--notes", "Fixed the login", "--locale", "fr-FR",
            "--no-notify", "--yes",
        ])
        #expect(give.command == .testFlightGive(TestFlightGiveCommand(
            build: "Alpha#43", add: ["QA", "Beta"], remove: ["Friends"], notes: "Fixed the login", locale: "fr-FR", notify: false, yes: true
        )))
        #expect(try CLIParser.parse(["testflight", "give", "Alpha#43", "--remove", "QA"]).command
            == .testFlightGive(TestFlightGiveCommand(build: "Alpha#43", remove: ["QA"])))
        #expect(try CLIParser.parse(["testflight", "give", "Alpha#43", "--group", "QA", "--notify"]).command
            == .testFlightGive(TestFlightGiveCommand(build: "Alpha#43", add: ["QA"], notify: true)))

        #expect(try CLIParser.parse(["testflight", "expire", "Alpha#43", "--yes", "--account", "Work"]).command
            == .testFlightExpire(TestFlightExpireCommand(build: "Alpha#43", yes: true)))
        #expect(try CLIParser.parse(["testflight", "--help"]).command == .help(topic: "testflight"))
        #expect(CLIParser.commandNames.contains("testflight"))
        #expect(CLIHelp.topic("testflight")?.contains("--group <name>") == true)
    }

    @Test(arguments: [
        ["testflight"],
        ["testflight", "give"],
        ["testflight", "give", "Alpha#43"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--remove", "qa"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--group", "Qa"],
        ["testflight", "give", "Alpha#43", "--group", " "],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--notes", "Fixed"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--locale", "fr-FR"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--notes", "Fixed", "--locale", "fr FR"],
        ["testflight", "give", "Alpha#43", "--remove", "QA", "--notes", "Fixed", "--locale", "fr-FR"],
        ["testflight", "give", "Alpha#43", "--remove", "QA", "--no-notify"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--notify", "--no-notify"],
        ["testflight", "give", "Alpha#43", "--group"],
        ["testflight", "give", "Alpha#43", "--group", "QA", "--clean"],
        ["testflight", "give", "Alpha#43", "Beta#2", "--group", "QA"],
        ["testflight", "expire"],
        ["testflight", "expire", "Alpha#43", "--group", "QA"],
        ["testflight", "Alpha#43", "--yes"],
    ])
    func aMistakeIsAUsageError(arguments: [String]) {
        #expect(throws: CLIFailure.self) { try CLIParser.parse(arguments) }
        do {
            _ = try CLIParser.parse(arguments)
        } catch {
            #expect(error.code == .usage && error.code.exitCode == 2)
        }
    }

    @Test func notesAreCappedAtWhatAppleTakes() {
        let long = String(repeating: "a", count: IPCTestFlightGiveRequest.maximumNotesLength + 1)

        #expect(throws: CLIFailure.self) { try CLIParser.parse(["testflight", "give", "Alpha#43", "--group", "QA", "--notes", long, "--locale", "en-US"]) }
    }
}

// MARK: - Groups and questions

struct TestFlightGroupResolutionTests {
    @Test func aGroupIsFoundByNameWhateverTheCaseOrByItsIdentifier() throws {
        let groups = TestFlightFixture.groups

        #expect(try CLITestFlightGroups.resolve("qa", in: groups).id == "g-qa")
        #expect(try CLITestFlightGroups.resolve("  BETA ", in: groups).id == "g-beta")
        #expect(try CLITestFlightGroups.resolve("g-friends", in: groups).name == "Friends")
    }

    @Test func anUnknownNameListsTheGroupsAndAnAmbiguousOneTheCandidates() {
        let groups = TestFlightFixture.groups + [BetaGroup(id: "g-qa-2", name: "qa", isInternal: false, receivesEveryBuild: false, testerCount: nil)]

        let unknown = #expect(throws: CLIFailure.self) { try CLITestFlightGroups.resolve("Nightly", in: groups) }
        #expect(unknown?.code == .notFound && unknown?.code.exitCode == 5)
        #expect(unknown?.suggestions.contains("Known group: QA (internal)") == true)
        #expect(unknown?.suggestions.contains("Known group: Internal (internal, receives every build)") == true)

        let ambiguous = #expect(throws: CLIFailure.self) { try CLITestFlightGroups.resolve("QA", in: groups) }
        #expect(ambiguous?.code == .ambiguous && ambiguous?.code.exitCode == 5)
        #expect(ambiguous?.suggestions == ["Use its id: g-qa (QA, internal)", "Use its id: g-qa-2 (qa, external)"])
    }

    @Test func theQuestionsNameTheBuildTheGroupsAndWhatCannotBeUndone() {
        let qa = TestFlightFixture.qa
        let beta = TestFlightFixture.beta

        #expect(CLITestFlightQuestion.give(app: "Alpha", label: "1.4 (412)", add: [qa, beta], remove: []) == "Give Alpha 1.4 (412) to QA and Beta (beta review first)? [y/N]")
        #expect(CLITestFlightQuestion.give(app: "Alpha", label: "1.4 (412)", add: [], remove: [qa]) == "Take Alpha 1.4 (412) from QA? [y/N]")
        #expect(CLITestFlightQuestion.give(app: "Alpha", label: "1.4 (412)", add: [beta], remove: [qa])
            == "Give Alpha 1.4 (412) to Beta (beta review first) and take it from QA? [y/N]")

        let build = TestFlightFixture.build(member: [TestFlightFixture.qa, TestFlightFixture.beta])
        let question = CLITestFlightQuestion.expire(app: "Alpha", label: "1.4 (412)", build: build, groups: TestFlightFixture.groups)
        #expect(question == "Expire Alpha 1.4 (412)? The 127 testers of Internal, QA and Beta will no longer be able to install it. An expiration can't be undone. [y/N]")

        var unknownCounts = TestFlightFixture.groups
        unknownCounts[1].testerCount = nil
        #expect(CLITestFlightQuestion.expire(app: "Alpha", label: "1.4 (412)", build: build, groups: unknownCounts).contains("The testers of Internal, QA and Beta will"))
        #expect(CLITestFlightQuestion.expire(app: "Alpha", label: "1.4 (412)", build: build, groups: nil).contains("Its testers will no longer"))

        var inReview = build
        inReview.externalState = .inReview
        #expect(CLITestFlightQuestion.expire(app: "Alpha", label: "1.4 (412)", build: inReview, groups: TestFlightFixture.groups).contains("The beta review in progress stops."))
    }
}

// MARK: - The answers of the command

struct TestFlightReadCommandTests {
    private func run(_ arguments: [String], _ environment: CLIEnvironment) async -> CLIResult {
        await CumulusCLI.run(arguments: arguments, environment: environment)
    }

    @Test func aBuildAnswersWithItsTestFlightBuildAndTheGroupsOfItsApp() async throws {
        let environment = try await CLIFixture.environment()
        try await TestFlightFixture.write(to: environment)

        let result = await run(["testflight", "Alpha#43", "--json"], environment)

        #expect(result.exitCode == 0)
        let (data, meta) = try CLIFixture.json(result)
        let object = try #require(data as? [String: Any])
        #expect(object["reference"] as? String == "Alpha#43" && object["buildRunID"] as? String == "run-a43" && object["hint"] == nil)
        let build = try #require(object["build"] as? [String: Any])
        #expect(build["label"] as? String == "1.4 (412)" && build["status"] as? String == "available" && build["daysLeft"] as? Int == 80)
        #expect(build["internalState"] as? String == "testing" && build["externalState"] as? String == "readyForSubmission")
        let groups = try #require(object["groups"] as? [[String: Any]])
        #expect(groups.compactMap { $0["name"] as? String } == ["Internal", "QA", "Beta", "Friends"])
        #expect(groups.compactMap { $0["hasBuild"] as? Bool } == [true, true, false, false], "the group that receives every build always has it")
        #expect(groups[0]["receivesEveryBuild"] as? Bool == true && groups[2]["kind"] as? String == "external" && groups[2]["testerCount"] as? Int == 120)
        #expect(meta["account"] as? String == "Personal")
    }

    @Test func aTableListsTheGroupsAtATerminal() async throws {
        var environment = try await CLIFixture.environment()
        environment.isTerminal = true
        try await TestFlightFixture.write(to: environment)

        let text = await run(["testflight", "Alpha#43"], environment).stdout

        #expect(text.contains("TestFlight") && text.contains("1.4 (412)  available, expires in 80 days"))
        #expect(text.contains("GROUP") && text.contains("HAS BUILD") && text.contains("yes (always)"))
    }

    @Test func withoutWhatTheAppWroteTheAnswerSaysSoAndDoesNotAskTheAppWhenItIsNotRunning() async throws {
        let environment = try await CLIFixture.environment()

        let (data, _) = try CLIFixture.json(await run(["testflight", "Alpha#43", "--json"], environment))
        let object = try #require(data as? [String: Any])

        #expect(object["build"] == nil && object["groups"] == nil)
        #expect((object["hint"] as? String)?.contains("has not listed") == true)

        try await TestFlightFixture.write(to: environment, build: nil, groups: nil)
        let none = try CLIFixture.json(await run(["testflight", "Alpha#43", "--json"], environment)).data as? [String: Any]
        #expect((none?["hint"] as? String)?.contains("has no TestFlight build") == true)

        let missing = await run(["testflight", "Alpha#999", "--json"], environment)
        #expect(missing.exitCode == 5 && missing.stderr.contains("NOT_FOUND"))
    }

    @Test func theRunningAppIsAskedToReadWhatIsMissingExactlyOnceAndNeverWithCached() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path

        _ = await run(["testflight", "Alpha#43", "--json"], environment)
        _ = await run(["testflight", "Alpha#43", "--json", "--cached"], environment)
        #expect(await service.testFlightLoads == ["run-a43"])

        try await TestFlightFixture.write(to: environment)
        _ = await run(["testflight", "Alpha#43", "--json"], environment)
        #expect(await service.testFlightLoads == ["run-a43"], "nothing is missing once the files are there")
        await socket.stop()
    }

    @Test func aRunningBuildHasNoTestFlightBuildYet() async throws {
        let environment = try await CLIFixture.environment()

        let (data, _) = try CLIFixture.json(await run(["testflight", "Alpha#45", "--json"], environment))

        #expect(((data as? [String: Any])?["hint"] as? String)?.contains("still running") == true)
    }
}

struct TestFlightWriteCommandTests {
    private func environment(socket path: String, terminal: Bool = false, groups: [BetaGroup]? = TestFlightFixture.groups) async throws -> CLIEnvironment {
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        environment.isTerminal = terminal
        try await TestFlightFixture.write(to: environment, groups: groups)
        return environment
    }

    @Test func giveSendsTheIdentifiersOfTheGroupsResolvedFromTheirNames() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        let environment = try await environment(socket: path)

        let result = await CumulusCLI.run(
            arguments: ["testflight", "give", "Alpha#43", "--group", "beta", "--remove", "QA", "--notes", "Try dark mode", "--locale", "en-US", "--notify", "--json"],
            environment: environment
        )

        #expect(result.exitCode == 0)
        #expect(await service.gives == [IPCTestFlightGiveRequest(
            testFlightBuildID: "tf-412", addGroupIDs: ["g-beta"], removeGroupIDs: ["g-qa"], notes: "Try dark mode", locale: "en-US", notify: true, accountID: "default"
        )])
        let (data, _) = try CLIFixture.json(result)
        let object = try #require(data as? [String: Any])
        #expect(object["action"] as? String == "give" && object["changed"] as? Bool == true && object["added"] as? [String] == ["QA"])
        #expect(object["build"] == nil, "the shared file was not refreshed, so no stale state is shown")
        // The keys are the contract agents read: a change here is a breaking change.
        #expect(Set(object.keys) == ["action", "added", "app", "appLaunched", "buildRunID", "changed", "reference", "removed", "steps", "unchanged"])
        await socket.stop()
    }

    @Test func atATerminalThePersonIsAskedFirstAndNothingIsSentWhenTheyDecline() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await environment(socket: path, terminal: true)
        let questions = Mutex<[String]>([])
        environment.confirm = { question in
            questions.withLock { $0.append(question) }
            return false
        }

        let declined = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "Beta", "--remove", "QA", "--table"], environment: environment)
        let expired = await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--table"], environment: environment)

        #expect(declined.stdout == "Nothing changed.\n" && expired.stdout == "Nothing changed.\n")
        #expect(questions.withLock { $0 } == [
            "Give Alpha 1.4 (412) to Beta (beta review first) and take it from QA? [y/N]",
            "Expire Alpha 1.4 (412)? The 7 testers of Internal and QA will no longer be able to install it. An expiration can't be undone. [y/N]",
        ])
        #expect(await service.gives.isEmpty)
        #expect(await service.expirations.isEmpty)

        environment.confirm = { _ in true }
        _ = await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--table"], environment: environment)
        _ = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "Beta", "--yes", "--table"], environment: environment)
        #expect(await service.expirations == [IPCTestFlightExpireRequest(testFlightBuildID: "tf-412", accountID: "default")])
        #expect(await service.gives.count == 1)
        await socket.stop()
    }

    @Test func inAPipeNoQuestionIsAskedBecauseTheAgentDecided() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await environment(socket: path)
        environment.confirm = { _ in false }

        let result = await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--json"], environment: environment)

        #expect(result.exitCode == 0 && result.stdout.contains("\"action\" : \"expire\""))
        #expect(await service.expirations.count == 1)
        await socket.stop()
    }

    @Test func aNameTheAppDoesNotKnowIsRefusedBeforeAnythingIsSent() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        let environment = try await environment(socket: path)

        let unknown = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "Nightly", "--json"], environment: environment)
        #expect(unknown.exitCode == 5 && unknown.stderr.contains("NOT_FOUND") && unknown.stderr.contains("Known group: QA (internal)"))

        let fixed = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "Internal", "--json"], environment: environment)
        #expect(fixed.exitCode == 2 && fixed.stderr.contains("receives every build by itself"))

        let twice = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "QA", "--remove", "g-qa", "--json"], environment: environment)
        #expect(twice.exitCode == 2 && twice.stderr.contains("named twice"))
        #expect(await service.gives.isEmpty)
        await socket.stop()
    }

    @Test func withoutTheGroupsOfTheAppTheCommandSaysSoAndSendsNothing() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        let environment = try await environment(socket: path, groups: nil)

        let result = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "QA", "--json"], environment: environment)

        #expect(result.exitCode == 5 && result.stderr.contains("has not read the groups"))
        #expect(await service.testFlightLoads == ["run-a43"], "the app was asked to read them first")
        #expect(await service.gives.isEmpty)
        await socket.stop()
    }

    @Test func theNewStateComesFromTheFileWhenTheAppReadTheBuildBack() async throws {
        let service = FakeIPCService()
        await service.set(expireResult: IPCResult(written: true, refreshed: true))
        let (socket, path) = try await IPCTestSocket.server(service)
        let environment = try await environment(socket: path)
        try await TestFlightFixture.write(to: environment, build: TestFlightFixture.build(expired: true))

        let (data, _) = try CLIFixture.json(await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--yes", "--json"], environment: environment))

        let build = try #require((data as? [String: Any])?["build"] as? [String: Any])
        #expect(build["status"] as? String == "expired")
        await socket.stop()
    }

    @Test func eachRefusalOfTheAppBecomesTheErrorCodeAnAgentBranchesOn() {
        func failure(_ reason: String, message: String? = nil, names: [String]? = nil) -> CLIFailure {
            CLIAppLink.testFlightFailure(for: IPCResult(reason: reason, message: message, written: false, names: names))
        }

        #expect(failure(IPCTestFlightReason.notAllowed).code == .notAllowed && CLIErrorCode.notAllowed.exitCode == 7)
        #expect(failure(IPCTestFlightReason.capReached).code == .rateLimited && failure(IPCTestFlightReason.rateLimited).code.exitCode == 8)
        #expect(failure(IPCTestFlightReason.refused, message: "Refused No.").code == .refused)
        #expect(failure(IPCTestFlightReason.refused, message: "Refused No.").message.hasSuffix("Refused No."))
        #expect(failure(IPCTestFlightReason.unknownBuild).code.exitCode == 5)
        #expect(failure(IPCTestFlightReason.noCredentials).code == .noCache && failure(IPCTestFlightReason.unknownAccount).code == .notFound)
        #expect(failure(IPCTestFlightReason.buildNotReady, message: "Processing.").code.exitCode == 1)
        #expect(failure(IPCTestFlightReason.groupNotChoosable).code == .usage)
        #expect(failure(IPCTestFlightReason.groupsUnreadable).code == .internal)
        let unknown = failure(IPCTestFlightReason.unknownGroup, names: ["QA", "Beta"])
        #expect(unknown.code == .notFound && unknown.suggestions.prefix(2) == ["Known group: QA", "Known group: Beta"])
        let uncertain = failure(IPCTestFlightReason.uncertain)
        #expect(uncertain.code == .internal && uncertain.suggestions.contains { $0.contains("Do not try again yet") })
    }

    @Test func anAnswerOfTheAppTurnsIntoAnErrorOnStandardError() async throws {
        let service = FakeIPCService()
        await service.set(giveResult: IPCResult(reason: IPCTestFlightReason.capReached, message: "Next at 15:00.", written: false))
        let (socket, path) = try await IPCTestSocket.server(service)
        let environment = try await environment(socket: path)

        let capped = await CumulusCLI.run(arguments: ["testflight", "give", "Alpha#43", "--group", "Beta", "--yes", "--json"], environment: environment)
        #expect(capped.exitCode == 8 && capped.stderr.contains("RATE_LIMITED") && capped.stderr.contains("Next at 15:00."))

        await service.set(expireResult: IPCResult(reason: IPCTestFlightReason.notAllowed, written: false))
        let forbidden = await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--yes", "--json"], environment: environment)
        #expect(forbidden.exitCode == 7 && forbidden.stderr.contains("NOT_ALLOWED"))
        await socket.stop()
    }

    @Test func withoutTheAppRunningTheWriteCannotBeMade() async throws {
        var environment = try await CLIFixture.environment()
        try await TestFlightFixture.write(to: environment)
        environment.socketPath = IPCTestSocket.path()

        let result = await CumulusCLI.run(arguments: ["testflight", "expire", "Alpha#43", "--yes", "--json"], environment: environment)

        #expect(result.exitCode == 4 && result.stderr.contains("APP_UNREACHABLE"))
    }
}

// MARK: - The socket

struct TestFlightProtocolTests {
    private func response(_ params: String, method: String = "testFlightGive") async -> IPCResponse {
        await IPCDispatcher(service: FakeIPCService()).response(to: Data(#"{"id":"1","method":"\#(method)","params":\#(params)}"#.utf8))
    }

    @Test func aGiveNamesABuildAndGroupsAndNothingElseUnusual() async {
        #expect(await response(#"{"testFlightBuildID":"tf-1"}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"addGroupIDs":["g1"]}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"tf-1","addGroupIDs":["g1","g1"]}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"tf-1","addGroupIDs":["g1"],"removeGroupIDs":["g1"]}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"../x","addGroupIDs":["g1"]}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"tf-1","addGroupIDs":["g 1"]}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"tf-1","addGroupIDs":["g1"],"notes":"x"}"#).error?.code == IPCFailure.invalidParams, "notes need a locale")
        #expect(await response(#"{"testFlightBuildID":"tf-1","addGroupIDs":["g1"],"locale":"fr-FR"}"#).error?.code == IPCFailure.invalidParams, "a locale needs notes")
        #expect(await response(#"{"testFlightBuildID":"tf-1","removeGroupIDs":["g1"],"notes":"x","locale":"fr-FR"}"#).error?.code == IPCFailure.invalidParams, "notes go with an added group")
        #expect(await response(#"{"testFlightBuildID":"tf-1","removeGroupIDs":["g1"],"notify":true}"#).error?.code == IPCFailure.invalidParams)
        let accepted = await response(#"{"accountID":"default","testFlightBuildID":"tf-1","addGroupIDs":["g1"],"removeGroupIDs":["g2"],"notes":"x","locale":"fr-FR","notify":false}"#)
        #expect(accepted.result?.written == true && accepted.error == nil)
    }

    @Test func anExpireAndALoadNameABuild() async {
        #expect(await response("{}", method: "testFlightExpire").error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"a/b"}"#, method: "testFlightExpire").error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"testFlightBuildID":"tf-1","accountID":"default"}"#, method: "testFlightExpire").result?.written == true)
        #expect(await response("{}", method: "testFlightLoad").error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"buildRunID":"run-a43"}"#, method: "testFlightLoad").result?.loaded == true)
    }

    @Test func theRequestsRoundTripThroughTheirParams() {
        let give = IPCTestFlightGiveRequest(
            testFlightBuildID: "tf-1", addGroupIDs: ["g1"], removeGroupIDs: ["g2"], notes: "x", locale: "en-US", notify: true, accountID: "acc"
        )
        let expire = IPCTestFlightExpireRequest(testFlightBuildID: "tf-1", accountID: "acc")

        #expect(IPCTestFlightGiveRequest(params: give.params) == give)
        #expect(IPCTestFlightExpireRequest(params: expire.params) == expire)
        #expect(IPCTestFlightGiveRequest(testFlightBuildID: "b", removeGroupIDs: ["g"]).params.addGroupIDs == nil, "an empty list is not sent")
    }
}

// MARK: - The app

@MainActor
struct AgentTestFlightServiceTests {
    private let moment = Date(timeIntervalSince1970: 1_795_125_600)

    /// Where the writes of a test went, and the banners it caused.
    private final class Recorder: Sendable {
        let writes = Mutex<[URLRequest]>([])
        let banners = Mutex<[LocalNotification]>([])

        var shapes: [String] { writes.withLock { $0 }.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }
    }

    private struct Harness {
        let accounts: TestAccounts
        let session: AccountSession
        let service: AgentTestFlightService
        let recorder: Recorder
        let clock: TestClock
    }

    /// An account whose key Apple "accepts" through a transport that records every write and answers `reply` to the others.
    private func harness(
        build: TestFlightBuild? = TestFlightFixture.build(now: Date(timeIntervalSince1970: 1_795_125_600)), keyAccess: KeyAccess = .canLaunch,
        reply: @escaping @Sendable (URLRequest) -> MockTransport.Reply? = { _ in nil }
    ) async throws -> Harness {
        let recorder = Recorder()
        let accounts = TestAccounts()
        accounts.transport = MockTransport { request in
            if request.httpMethod != "GET" { recorder.writes.withLock { $0.append(request) } }
            if let answer = reply(request) { return answer }
            if request.url?.path().hasSuffix("/betaBuildLocalizations") == true, let data = try? Fixture.data("betaBuildLocalizations") {
                return MockTransport.Reply(body: data)
            }
            return request.httpMethod == "GET" ? MockTransport.Reply(status: 404) : MockTransport.Reply(status: 204)
        }
        let credentials = StoredCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let session = try await accounts.model.add(name: "Personal", credentials: credentials, keyAccess: keyAccess)
        if let build {
            let reading = TestFlightReading(appID: "111", builds: [build], readAt: moment)
            await TestFlightCache(fileURL: session.paths.testFlight).save(TestFlightFile(readings: ["p-alpha": reading]))
        }
        await BetaGroupsCache(fileURL: session.paths.testFlightGroups).save(
            BetaGroupsFile(readings: ["111": BetaGroupsReading(appID: "111", groups: TestFlightFixture.groups, readAt: moment)])
        )
        try await BuildCacheStore(fileURL: session.paths.buildCache).save(CLIFixture.snapshot)
        let clock = TestClock(moment)
        let preferences = NotificationPreferences(defaults: accounts.defaults)
        let service = AgentTestFlightService(
            accounts: accounts.model, preferences: preferences, notify: { banners in recorder.banners.withLock { $0 += banners } }, now: { clock.now }
        )
        return Harness(accounts: accounts, session: session, service: service, recorder: recorder, clock: clock)
    }

    private func give(_ add: [String] = [], remove: [String] = [], notes: String? = nil, locale: String? = nil, notify: Bool? = nil, on harness: Harness) async -> IPCResult {
        await harness.service.give(IPCTestFlightGiveRequest(
            testFlightBuildID: "tf-412", addGroupIDs: add, removeGroupIDs: remove, notes: notes, locale: locale, notify: notify, accountID: harness.session.id
        ))
    }

    private func expire(on harness: Harness) async -> IPCResult {
        await harness.service.expire(IPCTestFlightExpireRequest(testFlightBuildID: "tf-412", accountID: harness.session.id))
    }

    @Test func givingAndTakingAreOneRequestEachAndTheUserIsTold() async throws {
        let harness = try await harness()

        let result = await give(["g-beta"], remove: ["g-qa"], on: harness)

        #expect(result.written == true && result.reason == nil)
        #expect(result.addedGroups == ["Beta"] && result.removedGroups == ["QA"] && result.unchangedGroups == [])
        #expect(result.steps == ["addGroups", "removeGroups"])
        #expect(harness.recorder.shapes == ["POST /v1/builds/tf-412/relationships/betaGroups", "DELETE /v1/builds/tf-412/relationships/betaGroups"])
        let banner = try #require(harness.recorder.banners.withLock { $0.first })
        #expect(banner.title == "TestFlight build given by an agent" && banner.body.contains("Beta") && banner.body.contains("QA"))
        #expect(banner.url == CumulusURL.app(productID: "p-alpha"))
    }

    @Test func aGroupAlreadyAsAskedIsNotSentAgain() async throws {
        let harness = try await harness()

        let result = await give(["g-qa"], remove: ["g-beta"], on: harness)

        #expect(result.written == false && result.reason == nil && result.unchangedGroups == ["QA", "Beta"])
        #expect(harness.recorder.writes.withLock { $0.isEmpty } && harness.recorder.banners.withLock { $0.isEmpty })
    }

    @Test func theNotesAreWrittenFirstOverTheLanguageTheyAreFor() async throws {
        let harness = try await harness()

        let result = await give(["g-beta"], notes: "Try the new queue", locale: "fr-FR", notify: false, on: harness)

        #expect(result.written == true && result.steps == ["notes", "notification", "addGroups"])
        #expect(harness.recorder.shapes == [
            "PATCH /v1/betaBuildLocalizations/a11ce013-0000-4000-8000-000000001013", "PATCH /v1/buildBetaDetails/detail-1",
            "POST /v1/builds/tf-412/relationships/betaGroups",
        ])
    }

    @Test func aGroupUnknownToTheAppListsTheOnesItKnowsAndSendsNothing() async throws {
        let harness = try await harness()

        let unknown = await give(["g-nope"], on: harness)
        #expect(unknown.reason == IPCTestFlightReason.unknownGroup && unknown.names == ["Internal", "QA", "Beta", "Friends"] && unknown.written == false)

        let fixed = await give(["g-all"], on: harness)
        #expect(fixed.reason == IPCTestFlightReason.groupNotChoosable)

        let build = await harness.service.give(IPCTestFlightGiveRequest(testFlightBuildID: "tf-other", addGroupIDs: ["g-beta"], accountID: harness.session.id))
        #expect(build.reason == IPCTestFlightReason.unknownBuild)
        #expect(harness.recorder.writes.withLock { $0.isEmpty })
    }

    @Test func aBuildThatCannotBeDistributedIsRefusedWithTheReason() async throws {
        for (build, expected) in [
            (TestFlightFixture.build(processing: .processing, now: moment), "processing"),
            (TestFlightFixture.build(expired: true, now: moment), "expired"),
            (TestFlightFixture.build(internalState: .missingCompliance, now: moment), "encryption"),
        ] {
            let harness = try await harness(build: build)

            let result = await give(["g-beta"], on: harness)

            #expect(result.reason == IPCTestFlightReason.buildNotReady && result.message?.contains(expected) == true, "\(expected)")
            #expect(harness.recorder.writes.withLock { $0.isEmpty })
        }
    }

    @Test func aReadOnlyKeyOrAnUnknownAccountSendsNothing() async throws {
        let readOnly = try await harness(keyAccess: .readOnly)
        let blocked = await give(["g-beta"], on: readOnly)
        #expect(blocked.reason == IPCTestFlightReason.notAllowed && blocked.message?.contains("read-only") == true)
        #expect(await expire(on: readOnly).reason == IPCTestFlightReason.notAllowed)
        #expect(readOnly.recorder.writes.withLock { $0.isEmpty })

        let open = try await harness()
        #expect(await give(["g-beta"], on: open).written == true)

        let missing = await open.service.give(IPCTestFlightGiveRequest(testFlightBuildID: "tf-412", addGroupIDs: ["g-beta"], accountID: "gone"))
        #expect(missing.reason == IPCTestFlightReason.unknownAccount)
    }

    @Test func aForbiddenAnswerPutsTheKeyInReadOnlyModeAndIsNotRepeated() async throws {
        let harness = try await harness(reply: { $0.httpMethod == "POST" ? MockTransport.Reply(status: 403) : nil })

        let result = await give(["g-beta"], on: harness)

        #expect(result.reason == IPCTestFlightReason.notAllowed && result.written == false)
        #expect(harness.session.settings.keyAccess == .readOnly)
        #expect(harness.recorder.shapes == ["POST /v1/builds/tf-412/relationships/betaGroups"], "one request, never a second")
        #expect(await give(["g-beta"], on: harness).reason == IPCTestFlightReason.notAllowed)
        #expect(harness.recorder.shapes.count == 1)
    }

    @Test func applesRefusalComesBackWithItsWordsAndWhatWasAlreadyDone() async throws {
        let body = Data(#"{"errors":[{"status":"409","code":"X","title":"Refused","detail":"No."}]}"#.utf8)
        let harness = try await harness(reply: { $0.httpMethod == "POST" ? MockTransport.Reply(status: 409, body: body) : nil })

        let result = await give(["g-beta"], remove: ["g-qa"], on: harness)

        #expect(result.reason == IPCTestFlightReason.refused && result.message?.hasSuffix("Refused No.") == true && result.written == false)
        #expect(harness.recorder.shapes == ["POST /v1/builds/tf-412/relationships/betaGroups"], "the removal is not tried after the refusal")
        #expect(harness.recorder.banners.withLock { $0.isEmpty })
    }

    @Test func aTimeoutIsUncertainAndNeverSentAgain() async throws {
        let harness = try await harness(reply: { $0.httpMethod == "POST" ? MockTransport.Reply(error: URLError(.timedOut)) : nil })

        let result = await give(["g-beta"], on: harness)

        #expect(result.reason == IPCTestFlightReason.uncertain && result.written == false)
        #expect(harness.recorder.shapes == ["POST /v1/builds/tf-412/relationships/betaGroups"])
    }

    @Test func anExpirationIsOnePatchAndTheUserIsToldItCannotBeUndone() async throws {
        let harness = try await harness()

        let result = await expire(on: harness)

        #expect(result.written == true && result.reason == nil)
        #expect(harness.recorder.shapes == ["PATCH /v1/builds/tf-412"])
        let banner = try #require(harness.recorder.banners.withLock { $0.first })
        #expect(banner.title == "TestFlight build expired by an agent" && banner.body == "Alpha 1.4 (412)")
    }

    @Test func aBuildAlreadyExpiredIsLeftAloneAndAnUnprocessedOneIsRefused() async throws {
        let expired = try await harness(build: TestFlightFixture.build(expired: true, now: moment))
        let done = await expire(on: expired)
        #expect(done.written == false && done.reason == nil && expired.recorder.writes.withLock { $0.isEmpty })

        let processing = try await harness(build: TestFlightFixture.build(processing: .processing, now: moment))
        #expect(await expire(on: processing).reason == IPCTestFlightReason.buildNotReady)
    }

    @Test func theBannersCanBeTurnedOff() async throws {
        let harness = try await harness()
        NotificationPreferences(defaults: harness.accounts.defaults).builds.agentTestFlight = false
        let quiet = AgentTestFlightService(
            accounts: harness.accounts.model, preferences: NotificationPreferences(defaults: harness.accounts.defaults),
            notify: { banners in harness.recorder.banners.withLock { $0 += banners } }, now: { harness.clock.now }
        )

        _ = await quiet.expire(IPCTestFlightExpireRequest(testFlightBuildID: "tf-412", accountID: harness.session.id))

        #expect(harness.recorder.shapes == ["PATCH /v1/builds/tf-412"] && harness.recorder.banners.withLock { $0.isEmpty })
        #expect(NotificationPreferences(defaults: harness.accounts.defaults).builds.agentTestFlight == false)
        #expect(BuildNotificationRules().agentTestFlight, "on by default")
    }

    @Test func tenWritesAnHourPerAccountGivingOrExpiringThenTheCapSpeaksUntilTheOldestLeavesTheHour() async throws {
        let body = Data(#"{"errors":[{"status":"409","code":"X","title":"Refused","detail":"No."}]}"#.utf8)
        let refuse = Mutex(false)
        let harness = try await harness(reply: { _ in refuse.withLock { $0 } ? MockTransport.Reply(status: 409, body: body) : nil })

        refuse.withLock { $0 = true }
        for _ in 0..<4 { #expect(await give(["g-beta"], on: harness).reason == IPCTestFlightReason.refused) }
        refuse.withLock { $0 = false }
        for index in 0..<10 {
            let result = index.isMultiple(of: 2) ? await give(["g-beta"], on: harness) : await expire(on: harness)
            #expect(result.written == true, "write \(index + 1): a refusal Apple gave does not count")
            harness.clock.advance(by: 60)
        }
        let capped = await give(["g-beta"], on: harness)
        #expect(capped.reason == IPCTestFlightReason.capReached && capped.message?.contains("10") == true)
        #expect(await expire(on: harness).reason == IPCTestFlightReason.capReached)

        harness.clock.advance(by: 3600)
        #expect(await give(["g-beta"], on: harness).written == true, "the hour has passed")
    }

    @Test func theCapIsItsOwnAndNotTheThreeLaunchesOfRun() {
        #expect(AgentTestFlightGate.cap == 10 && AgentLaunchGate.cap == 3)
        let writes = (0..<10).map { moment.addingTimeInterval(-Double($0) * 60) }

        #expect(!AgentTestFlightGate.allows(writes, now: moment).allowed)
        #expect(AgentTestFlightGate.allows(Array(writes.prefix(9)), now: moment).allowed)
        #expect(AgentLaunchGate.allows(Array(writes.prefix(3)), now: moment).allowed == false, "launches keep their own count")
    }

    @Test func loadingReadsTheGroupsOfTheAppForTheCommandAndOnlyReads() async throws {
        let groupsBody = try Fixture.data("betaGroups-app")
        let harness = try await harness(reply: {
            $0.url?.path() == "/v1/apps/111/betaGroups" ? MockTransport.Reply(body: groupsBody) : nil
        })
        try await BuildCacheStore(fileURL: harness.session.paths.buildCache).save(CLIFixture.snapshot)

        #expect(await harness.service.load(buildRunID: "no-such-build").loaded == false)
        #expect(await harness.service.load(buildRunID: "run-a45").loaded == false, "a build still running has nothing to read")
        #expect(await harness.service.load(buildRunID: "run-a43").loaded == true)

        #expect(harness.session.testFlightGroups.groups(for: "111")?.map(\.name) == ["Internal", "QA", "External testers", "Friends"])
        let onDisk = await BetaGroupsCache(fileURL: harness.session.paths.testFlightGroups).load()
        #expect(onDisk?.readings["111"]?.groups.count == 4, "the file the command reads holds what was read")
        #expect(harness.recorder.writes.withLock { $0.isEmpty })
    }
}
