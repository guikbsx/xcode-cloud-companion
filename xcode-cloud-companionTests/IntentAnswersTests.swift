import AppIntents
import Foundation
import Testing
@testable import XcodeCloudCompanion

struct IntentAnswersTests {
    private let english = Locale(identifier: "en_US")

    private func answers(_ environment: CLIEnvironment? = nil) async throws -> IntentAnswers {
        let environment = if let environment { environment } else { try await CLIFixture.environment() }
        return IntentAnswers(environment: environment, locale: english)
    }

    @Test func theLatestBuildIsTheNewestOneOfEveryAppOrOfOne() async throws {
        let answers = try await answers()

        let latest = try await answers.latestBuild()
        #expect(latest.id == "run-g8" && latest.isRunning && latest.status == .running)

        let ofAlpha = try await answers.latestBuild(app: "Alpha")
        #expect(ofAlpha.reference == "Alpha#45" && ofAlpha.app == "Alpha")
        #expect(ofAlpha.link?.absoluteString == "cumulus://build/run-a45")

        let byProductID = try await answers.latestBuild(app: "p-beta")
        #expect(byProductID.reference == "Beta#10" && byProductID.status == .succeeded && byProductID.durationMinutes == 20)
    }

    @Test func runningBuildsAreOnlyTheOnesThatWaitOrRun() async throws {
        let running = try await answers().builds(running: true, limit: 20)

        #expect(Set(running.map(\.id)) == ["run-a45", "run-g8"])
        #expect(running.filter { !$0.isRunning }.isEmpty)
    }

    @Test func theAppsAreTheOnesTheAccountFollows() async throws {
        let apps = try await answers().apps()

        #expect(apps.map(\.name) == ["Alpha", "Beta", "Gamma Tools"] || Set(apps.map(\.name)) == ["Alpha", "Beta", "Gamma Tools"])
        #expect(apps.first { $0.name == "Beta" }?.displayName == "Suite")
    }

    @Test func aBuildIsSaidInOneSentence() async throws {
        let answers = try await answers()
        let build = try await answers.latestBuild(app: "Beta")

        let sentence = answers.sentence(for: build)

        #expect(sentence.hasPrefix("Beta#10: Succeeded"))
        #expect(sentence.contains("20 min"))
    }

    @Test func whileBuildsAreMeasuredNoFigureIsSaid() async throws {
        let sentence = try await answers().usageSentence()

        #expect(sentence == "Cumulus is still measuring the builds of this cycle.")
    }

    @Test func theUsageSentenceSaysItIsAnEstimate() async throws {
        var measured = CLIFixture.snapshot
        measured.testDevicesByActionID["b8-test"] = [CITestDeviceRun(deviceName: "iPhone 16", osVersion: "18.0", testCount: 20, failedCount: 0, totalSeconds: 240)]
        let sentence = try await answers(CLIFixture.environment(snapshot: measured)).usageSentence()

        #expect(sentence.hasPrefix("About "))
        #expect(sentence.contains("of 25 hr used") && sentence.contains("an estimate"))
        #expect(sentence.contains("%") && sentence.contains("resets on"))
    }

    @Test func withoutAPlanTheSentenceSaysSo() async throws {
        let environment = try await CLIFixture.environment(plan: nil)

        let sentence = try await answers(environment).usageSentence()

        #expect(sentence.hasPrefix("No plan is set"))
    }

    @Test func nothingToReadAndAnUnknownAppAreSaidInWords() async throws {
        let empty = try await CLIFixture.environment(snapshot: nil)
        await #expect(throws: IntentAnswers.Failure(reason: .noData)) { try await self.answers(empty).latestBuild() }

        let answers = try await answers()
        await #expect(throws: IntentAnswers.Failure(reason: .unknownApp("Nope"))) { try await answers.latestBuild(app: "Nope") }
    }

    @Test func everyStateTheCommandNamesHasItsStateInTheInterface() {
        #expect(IntentAnswers.status(named: "pending") == .running && IntentAnswers.status(named: "running") == .running)
        #expect(IntentAnswers.status(named: "succeeded") == .succeeded && IntentAnswers.status(named: "failed") == .failed)
        #expect(IntentAnswers.status(named: "errored") == .errored && IntentAnswers.status(named: "canceled") == .canceled)
        #expect(IntentAnswers.status(named: "skipped") == .skipped && IntentAnswers.status(named: "anything") == .finished)
    }

    /// The system makes and describes intents and entities off the main actor: none of it may be tied to it.
    @Test func intentsAndEntitiesAreMadeAndReadOffTheMainActor() async throws {
        let answers = try await answers()
        let build = try await answers.latestBuild(app: "Beta")
        let app = try #require(try await answers.apps().first)
        await Task.detached {
            let intents: [any AppIntent.Type] = [LatestBuildIntent.self, RunningBuildsIntent.self, CycleUsageIntent.self]
            for intent in intents {
                _ = intent.init()
                _ = intent.title
            }
            let entity: any AppEntity = BuildEntity(build, summary: answers.sentence(for: build))
            _ = entity.displayRepresentation
            let followed: any AppEntity = FollowedAppEntity(app)
            _ = followed.displayRepresentation
            _ = CumulusShortcuts.appShortcuts.count
        }.value
        #expect(CumulusShortcuts.appShortcuts.count == 3)
    }
}
