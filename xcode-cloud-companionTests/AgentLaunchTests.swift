import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AgentLaunchGateTests {
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    @Test func threeLaunchesAnHourThenTheNextIsNamed() {
        let earlier = [now.addingTimeInterval(-3000), now.addingTimeInterval(-2000), now.addingTimeInterval(-100)]

        #expect(AgentLaunchGate.allows([], now: now).allowed)
        #expect(AgentLaunchGate.allows(Array(earlier.prefix(2)), now: now).allowed)
        let blocked = AgentLaunchGate.allows(earlier, now: now)
        #expect(!blocked.allowed && blocked.nextAt == now.addingTimeInterval(600), "when the oldest of the three leaves the hour")
        #expect(AgentLaunchGate.allows(earlier + [now.addingTimeInterval(-4000)], now: now).nextAt == now.addingTimeInterval(600), "an older launch no longer counts")
        #expect(AgentLaunchGate.allows(earlier.map { $0.addingTimeInterval(-700) }, now: now).allowed, "the oldest is more than an hour old")
    }
}

struct LaunchProtocolTests {
    @Test func aLaunchNamesOneWorkflowAndExactlyOneSource() async throws {
        let dispatcher = IPCDispatcher(service: FakeIPCService())
        func response(_ params: String) async -> IPCResponse {
            await dispatcher.response(to: Data(#"{"id":"1","method":"launch","params":\#(params)}"#.utf8))
        }

        #expect(await response(#"{"workflowID":"w-ci","branch":"main","tag":"v1"}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"workflowID":"w-ci"}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"branch":"main"}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"workflowID":"../x","branch":"main"}"#).error?.code == IPCFailure.invalidParams)
        #expect(await response(#"{"workflowID":"w-ci","pullRequest":0}"#).error?.code == IPCFailure.invalidParams)
        let accepted = await response(#"{"workflowID":"w-ci","pullRequest":12,"clean":true,"accountID":"default"}"#)
        #expect(accepted.result?.launched == true && accepted.result?.buildNumber == 46)
    }

    @Test func theParamsRoundTrip() {
        let request = IPCLaunchRequest(workflowID: "w", source: .tag("v1.0"), clean: true, accountID: "acc")

        #expect(IPCLaunchRequest(params: request.params) == request)
        #expect(request.params.tag == "v1.0" && request.params.branch == nil && request.params.clean == true)
        #expect(IPCLaunchRequest(workflowID: "w", source: .branch("main")).params.clean == nil, "clean is sent only when asked for")
        #expect(IPCLaunchRequest.Source.pullRequest(7).label == "PR #7")
    }
}

@MainActor
struct LaunchCommandTests {
    @Test func runTakesAWorkflowAndAtMostOneSource() throws {
        #expect(try CLIParser.parse(["run", "Release", "--pr", "#12", "--clean", "--yes"]).command == .launch(LaunchCommand(workflow: "Release", pullRequest: 12, clean: true, yes: true)))
        #expect(try CLIParser.parse(["run", "Alpha/CI", "--branch", "main"]).command == .launch(LaunchCommand(workflow: "Alpha/CI", branch: "main")))
        #expect(try CLIParser.parse(["run", "CI", "--account", "Work"]).account == "Work")
        #expect(throws: CLIFailure.self) { try CLIParser.parse(["run"]) }
        #expect(throws: CLIFailure.self) { try CLIParser.parse(["run", "CI", "--branch", "a", "--tag", "b"]) }
        #expect(throws: CLIFailure.self) { try CLIParser.parse(["run", "CI", "--pr", "x"]) }
    }

    @Test func aWorkflowIsFoundByNameOrByAppAndName() async throws {
        let environment = try await CLIFixture.environment()
        let scope = try await CLIAccountScope.resolve(nil, in: environment.directory)
        let snapshot = try await CLIData.load(from: scope.directory, includingUsage: false).snapshot

        #expect(try CLIReference.workflow("ci", in: snapshot).id == "w-ci")
        #expect(try CLIReference.workflow("Alpha/CI", in: snapshot).id == "w-ci")
        #expect(try CLIReference.workflow("w-release", in: snapshot).name == "Release")
        #expect(throws: CLIFailure.self) { try CLIReference.workflow("Nightly", in: snapshot) }
    }

    @Test func thePlanTakesTheBranchOfTheLastBuildWhenNoneIsGiven() async throws {
        let runner = CLIQueryRunner(environment: try await CLIFixture.environment(), account: nil)

        let plan = try await runner.prepareLaunch(LaunchCommand(workflow: "CI"))
        let tagged = try await runner.prepareLaunch(LaunchCommand(workflow: "Beta/Release", tag: "v1.1", clean: true))

        #expect(plan.request == IPCLaunchRequest(workflowID: "w-ci", source: .branch("main"), clean: false, accountID: "default"))
        #expect(plan.workflowName == "CI" && plan.appName == "Alpha")
        #expect(tagged.request.source == .tag("v1.1") && tagged.request.clean && tagged.appName == "Beta")
    }

    @Test func theAppsRefusalsBecomeErrorCodesAnAgentCanBranchOn() {
        func code(_ reason: String) -> CLIErrorCode { CLIAppLink.failure(for: IPCResult(reason: reason, launched: false)).code }

        #expect(code(IPCLaunchReason.notAllowed) == .notAllowed && CLIErrorCode.notAllowed.exitCode == 7)
        #expect(code(IPCLaunchReason.capReached) == .rateLimited && CLIErrorCode.rateLimited.exitCode == 8)
        #expect(code(IPCLaunchReason.rateLimited) == .rateLimited)
        #expect(code(IPCLaunchReason.refused) == .refused && CLIErrorCode.refused.exitCode == 1)
        #expect(code(IPCLaunchReason.unknownReference) == .notFound && code(IPCLaunchReason.unknownWorkflow) == .notFound)
        #expect(code(IPCLaunchReason.noCredentials) == .noCache && code(IPCLaunchReason.uncertain) == .internal)
        #expect(CLIAppLink.failure(for: IPCResult(reason: IPCLaunchReason.refused, launched: false, message: "Workflow disabled.")).message.hasSuffix("Workflow disabled."))
    }

    @Test func runAsksTheAppAndPrintsTheReference() async throws {
        let service = FakeIPCService()
        let (socket, path) = try await IPCTestSocket.server(service)
        var environment = try await CLIFixture.environment()
        environment.socketPath = path
        environment.isTerminal = true
        environment.confirm = { question in question.hasPrefix("Start CI on main for Alpha?") }

        let result = await CumulusCLI.run(arguments: ["run", "CI", "--table"], environment: environment)
        let declined = await CumulusCLI.run(arguments: ["run", "CI", "--branch", "develop", "--table"], environment: environment)

        #expect(result.exitCode == 0 && result.stdout.contains("Started Alpha#46 · CI · main.") && result.stdout.contains("cumulus build Alpha#46"))
        #expect(declined.stdout == "Nothing started.\n", "a question answered no starts nothing")
        #expect(await service.launches == [IPCLaunchRequest(workflowID: "w-ci", source: .branch("main"), clean: false, accountID: "default")])

        await service.set(launchResult: IPCResult(reason: IPCLaunchReason.capReached, launched: false, message: "Next at 15:00."))
        let refused = await CumulusCLI.run(arguments: ["run", "CI", "--yes", "--json"], environment: environment)
        #expect(refused.exitCode == 8 && refused.stderr.contains("RATE_LIMITED"))
        await socket.stop()
    }
}
