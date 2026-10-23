import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OverviewHeadlineTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Thursday 23 October 2026, 14:32.
    private var now: Date { date(10, 23, 14, 32) }

    private func words(_ locale: Locale = Locale(identifier: "en_US")) -> OverviewHeadlineWords {
        OverviewHeadlineWords(locale: locale, calendar: calendar)
    }

    // MARK: - A world to build scenes from

    private struct World {
        var products: [CIProduct] = []
        var workflows: [CIWorkflow] = []
        var runs: [CIBuildRun] = []
        var actions: [String: [CIBuildAction]] = [:]
        var xcodeVersions: [CIXcodeVersion] = []
        var summary: UsageSummary?
        var apple: AppleStatusKnowledge?
        var testFlight: [String: TestFlightReading] = [:]
        var flaky: [OverviewFlakyTests.Entry] = []
        var insights: [String: String] = [:]
        var pro: Set<ProFeature> = Set(ProFeature.allCases)
    }

    private func product(_ world: inout World, _ id: String, _ name: String) {
        guard !world.products.contains(where: { $0.id == id }) else { return }
        world.products.append(CIProduct(id: id, name: name, productType: "APP", appID: "app-\(id)", appName: nil, bundleID: nil))
    }

    private func workflow(_ world: inout World, _ id: String, _ name: String, product productID: String, xcode: String? = nil, enabled: Bool? = nil) {
        guard !world.workflows.contains(where: { $0.id == id }) else { return }
        var workflow = CIWorkflow(id: id, name: name, testDestinationCounts: [])
        workflow.productID = productID
        workflow.isEnabled = enabled
        workflow.xcodeVersion = xcode
        workflow.xcodeVersionName = xcode.map { "Xcode \($0)" }
        world.workflows.append(workflow)
    }

    @discardableResult
    private func run(
        _ world: inout World, _ number: Int, workflow workflowID: String, product productID: String, at created: Date, minutes: Double = 10,
        status: CICompletionStatus? = .succeeded, progress: CIExecutionProgress = .complete, action: (name: String, minutes: Double)? = nil
    ) -> CIBuildRun {
        let name = world.workflows.first { $0.id == workflowID }?.name
        let build = CIBuildRun(
            id: "\(workflowID)-\(number)", productID: productID, number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: workflowID, workflowName: name, sourceBranchOrTag: "main"
        )
        world.runs.append(build)
        if let action {
            world.actions[build.id] = [CIBuildAction(
                id: "\(build.id)-action", buildRunID: build.id, name: action.name, actionType: .test, startedDate: created,
                finishedDate: progress == .complete ? created.addingTimeInterval(action.minutes * 60) : nil,
                executionProgress: progress == .complete ? .complete : .running, completionStatus: progress == .complete ? status : nil,
                isRequiredToPass: true
            )]
        }
        return build
    }

    private func headline(_ world: World, locale: Locale? = nil, at moment: Date? = nil, stuckFactor: Int = 3) -> OverviewHeadline {
        let moment = moment ?? now
        let snapshot = BuildSnapshot(
            products: world.products, runs: world.runs, actionsByRunID: world.actions, workflows: world.workflows, xcodeVersions: world.xcodeVersions,
            lastSuccessfulSync: moment
        )
        let sidebar = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())
        let mosaic = OverviewMosaic(snapshot: snapshot, sidebar: sidebar, summary: world.summary, now: moment, calendar: calendar)
        var facts = OverviewHeadline.Facts(snapshot: snapshot, mosaic: mosaic, summary: world.summary, now: moment)
        facts.calendar = calendar
        facts.locale = locale ?? english
        facts.pro = world.pro
        facts.failureInsights = world.insights
        facts.appleStatus = world.apple
        facts.testFlight = world.testFlight
        facts.flakyTests = world.flaky
        facts.stuckFactor = stuckFactor
        return OverviewHeadline(facts)
    }

    // MARK: Scenes, one per situation

    /// Something that passes, always there: the quietest scene.
    private func baseline(_ world: inout World) {
        product(&world, "pbase", "Base")
        workflow(&world, "wbase", "Main", product: "pbase")
        for (index, day) in [18, 19, 20, 21].enumerated() {
            run(&world, 1 + index, workflow: "wbase", product: "pbase", at: date(10, day, 9))
        }
    }

    /// Nightly of Sextant fails on #203, #204 and #205 after a success on #202.
    private func broken(_ world: inout World) {
        product(&world, "psext", "Sextant")
        workflow(&world, "wnightly", "Nightly", product: "psext")
        run(&world, 202, workflow: "wnightly", product: "psext", at: date(10, 18, 2))
        run(&world, 203, workflow: "wnightly", product: "psext", at: date(10, 21, 2), status: .failed)
        run(&world, 204, workflow: "wnightly", product: "psext", at: date(10, 22, 2), status: .errored)
        run(&world, 205, workflow: "wnightly", product: "psext", at: date(10, 23, 2), status: .failed)
    }

    /// 1,400 of 1,500 minutes spent twenty days into a thirty-day cycle.
    private func plan(_ world: inout World, used: Double = 1_400) {
        let cycle = DateInterval(start: now.addingTimeInterval(-20 * 86_400), duration: 30 * 86_400)
        world.summary = UsageSummary(
            plan: UsagePlan(hours: 25, resetAnchor: cycle.start), cycle: cycle, now: now, billedMinutes: used, estimatedMinutes: 0, estimatedBuildCount: 0,
            lastImport: now, daily: [], buildsLast30Days: 0, byApp: []
        )
    }

    /// Brioche #412 has run its Test action for 48 minutes; it usually takes 12.
    private func stuck(_ world: inout World) {
        product(&world, "pbri", "Brioche")
        workflow(&world, "wrelease", "Release – iOS", product: "pbri")
        for index in 0..<5 {
            run(&world, 400 + index, workflow: "wrelease", product: "pbri", at: date(10, 10 + index, 9), minutes: 12, action: ("Test – iOS", 12))
        }
        run(&world, 412, workflow: "wrelease", product: "pbri", at: now.addingTimeInterval(-48 * 60), status: nil, progress: .running, action: ("Test – iOS", 48))
    }

    /// Release – iOS of Brioche went from 6 to 11 minutes at #397, on October 7.
    private func slowdown(_ world: inout World) {
        product(&world, "pbri", "Brioche")
        workflow(&world, "wslow", "Test – iOS", product: "pbri")
        for index in 0..<10 {
            let slow = index >= 5
            run(&world, 392 + index, workflow: "wslow", product: "pbri", at: date(10, 2 + index, 9), minutes: slow ? 11 : 6, action: ("Test – iOS", slow ? 11 : 6))
        }
    }

    /// An incident that began four hours ago still goes on; a build of Atelier stopped inside it.
    private func apple(_ world: inout World) {
        product(&world, "patelier", "Atelier")
        workflow(&world, "wmain", "Main", product: "patelier")
        run(&world, 50, workflow: "wmain", product: "patelier", at: now.addingTimeInterval(-3 * 3600), status: .errored)
        run(&world, 51, workflow: "wmain", product: "patelier", at: now.addingTimeInterval(-3600))
        world.apple = AppleStatusKnowledge(events: [AppleStatusEvent(start: now.addingTimeInterval(-4 * 3600), end: nil)], readAt: now.addingTimeInterval(-300))
    }

    /// Pollen #88 runs since two minutes, in a workflow that usually takes ten.
    private func running(_ world: inout World) {
        product(&world, "ppol", "Pollen")
        workflow(&world, "wpr", "PR checks", product: "ppol")
        for index in 0..<3 {
            run(&world, 80 + index, workflow: "wpr", product: "ppol", at: date(10, 15 + index, 9), minutes: 10)
        }
        run(&world, 88, workflow: "wpr", product: "ppol", at: now.addingTimeInterval(-120), status: nil, progress: .running, action: ("Test – iOS", 2))
    }

    private var scenes: [(OverviewHeadline.Situation, (inout World) -> Void)] {
        [
            (.broken, { broken(&$0) }), (.planRunsOut, { plan(&$0) }), (.stuckBuild, { stuck(&$0) }), (.slowdown, { slowdown(&$0) }),
            (.appleIncident, { apple(&$0) }), (.buildRunning, { running(&$0) }),
        ]
    }

    // MARK: - The eight situations

    @Test func eachSituationAloneIsTheHeadlineOnTopOfAQuietBaseline() {
        for (situation, apply) in scenes {
            var world = World()
            baseline(&world)
            apply(&world)
            #expect(headline(world).title.situation == situation, "\(situation)")
        }
        var passing = World()
        baseline(&passing)
        #expect(headline(passing).title.situation == .allPassing)
        #expect(headline(World()).title.situation == .reading)
    }

    @Test func theHighestSituationOfAnyTwoWins() {
        for first in scenes.indices {
            for second in scenes.indices where second > first {
                var world = World()
                baseline(&world)
                scenes[first].1(&world)
                scenes[second].1(&world)
                #expect(
                    headline(world).title.situation == scenes[first].0,
                    "\(scenes[first].0) and \(scenes[second].0) together give \(scenes[first].0)"
                )
            }
        }
    }

    @Test func theSituationsAreOrderedAsDecided() {
        #expect(OverviewHeadline.Situation.allCases == [.broken, .planRunsOut, .stuckBuild, .slowdown, .appleIncident, .buildRunning, .allPassing, .reading])
    }

    // MARK: - Broken

    @Test func aBrokenWorkflowNamesItsAppAndSaysSinceWhen() throws {
        var world = World()
        baseline(&world)
        broken(&world)

        let title = headline(world).title

        #expect(title.text == "Sextant has been broken for two days.")
        #expect(title.emphasized == "broken" && title.tone == .alert)
        #expect(title.lead == "Nightly has failed since #203, three times in a row.")
        #expect(title.actions.map(\.title) == ["Open #205", "Copy for an AI"])
        #expect(title.actions.map(\.action) == [.openBuild(runID: "wnightly-205"), .copyForAI(runID: "wnightly-205")])
    }

    @Test func theSentenceOfInBriefJoinsTheLeadOnlyWhenCachedAndOpenedByPro() {
        var world = World()
        baseline(&world)
        broken(&world)
        world.insights = ["wnightly-205": "Four RouteSolver tests fail since iOS 27."]

        #expect(headline(world).title.lead == "Nightly has failed since #203, three times in a row. Four RouteSolver tests fail since iOS 27.")

        world.pro.remove(.failureInsight)
        #expect(headline(world).title.lead == "Nightly has failed since #203, three times in a row.")
        world.pro.insert(.failureInsight)
        world.insights = [:]
        #expect(headline(world).title.lead == "Nightly has failed since #203, three times in a row.")
    }

    @Test func theDurationIsSaidInShortWords() {
        func text(firstFailure: Date) -> String {
            var world = World()
            baseline(&world)
            product(&world, "psext", "Sextant")
            workflow(&world, "wnightly", "Nightly", product: "psext")
            run(&world, 1, workflow: "wnightly", product: "psext", at: firstFailure, status: .failed)
            return headline(world).title.text
        }

        #expect(text(firstFailure: date(10, 22, 20)) == "Sextant has been broken since yesterday.")
        #expect(text(firstFailure: date(10, 21, 2)) == "Sextant has been broken for two days.")
        #expect(text(firstFailure: date(10, 15, 2)) == "Sextant has been broken for eight days.")
        #expect(text(firstFailure: date(10, 11, 2)) == "Sextant has been broken for 12 days.")
        #expect(text(firstFailure: date(10, 23, 11, 20)) == "Sextant has been broken for 3 hr.")
        #expect(text(firstFailure: date(10, 23, 14, 10)) == "Sextant has been broken for less than an hour.")
    }

    @Test func severalBrokenWorkflowsOfOneAppSayTheAppIsBrokenAndTheOthersBecomeNotes() throws {
        var world = World()
        baseline(&world)
        broken(&world)
        workflow(&world, "wmain", "Main", product: "psext")
        run(&world, 90, workflow: "wmain", product: "psext", at: date(10, 22, 9), status: .failed)

        let result = headline(world)

        #expect(result.title.text == "Sextant is broken.")
        #expect(result.title.lead == "Nightly has failed since #203, three times in a row.", "the longest run speaks")
        #expect(result.notes.map(\.kind) == [.broken])
        #expect(result.notes.first?.sentence == "Sextant · Main failed on #90.")
        #expect(result.notes.first?.target == .build(runID: "wmain-90"))
    }

    @Test func brokenWorkflowsInTwoAppsAreCountedAndTheWorstIsInTheLead() {
        var world = World()
        baseline(&world)
        broken(&world)
        product(&world, "ppol", "Pollen")
        workflow(&world, "wpol", "Main", product: "ppol")
        run(&world, 88, workflow: "wpol", product: "ppol", at: date(10, 22, 9), status: .failed)

        let result = headline(world)

        #expect(result.title.text == "Two apps are broken.")
        #expect(result.title.lead == "Sextant · Nightly has failed since #203, three times in a row.")
        #expect(result.notes.first?.sentence == "Pollen · Main failed on #88.")
    }

    @Test func aWorkflowThatSucceededSinceIsNotBrokenAndAPausedOneIsLeftAlone() {
        var world = World()
        baseline(&world)
        broken(&world)
        run(&world, 206, workflow: "wnightly", product: "psext", at: date(10, 23, 9))
        #expect(headline(world).title.situation == .allPassing)

        var paused = World()
        baseline(&paused)
        product(&paused, "psext", "Sextant")
        workflow(&paused, "wnightly", "Nightly", product: "psext", enabled: false)
        run(&paused, 1, workflow: "wnightly", product: "psext", at: date(10, 22, 2), status: .failed)
        #expect(headline(paused).title.situation == .allPassing)
    }

    // MARK: - Plan

    @Test func thePlanRunningOutNamesTheDayAndIsAnEstimate() throws {
        var world = World()
        baseline(&world)
        plan(&world)
        let summary = try #require(world.summary)
        let exhaustion = try #require(summary.exhaustionDate)

        let title = headline(world).title

        #expect(title.text == "The plan will run out on \(words().day(exhaustion)).")
        #expect(title.emphasized == words().day(exhaustion) && title.tone == .warning)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: exhaustion), to: calendar.startOfDay(for: summary.resetDate)).day ?? -1
        #expect(days > 0)
        #expect(title.lead == "\(days) days before the reset, at this cycle’s pace. Estimate.")
    }

    @Test func aSpentPlanIsSaidSpent() {
        var world = World()
        baseline(&world)
        plan(&world, used: 1_600)

        let title = headline(world).title

        #expect(title.text == "The plan is used up." && title.emphasized == "used up" && title.tone == .alert)
        #expect(title.lead?.hasPrefix("It resets on ") == true)
    }

    @Test func thePlanSaysNothingWithoutAPlanWhileMeasuringOrAtASafePace() {
        var world = World()
        baseline(&world)
        #expect(headline(world).title.situation == .allPassing, "no plan")

        plan(&world, used: 400)
        #expect(headline(world).title.situation == .allPassing, "a safe pace")

        plan(&world)
        world.summary?.measurement = MeasurementProgress(totalActions: 4, measuredActions: 1)
        #expect(headline(world).title.situation == .allPassing, "measuring")
        #expect(headline(world).notes.isEmpty)
    }

    // MARK: - Stuck

    @Test func aStuckBuildSaysHowLongItRunsAndWhatIsUsual() {
        var world = World()
        baseline(&world)
        stuck(&world)

        let title = headline(world).title

        #expect(title.text == "Brioche #412 has been running for 48 min.")
        #expect(title.emphasized == "48 min")
        #expect(title.lead == "Usually, Release – iOS finishes in 12 min.")
        #expect(title.actions.map(\.action) == [.openBuild(runID: "wrelease-412")])
    }

    @Test func theStuckRuleIsTheBannersAndFollowsTheFactor() {
        var world = World()
        baseline(&world)
        stuck(&world)

        #expect(headline(world, stuckFactor: 3).title.situation == .stuckBuild, "48 min against 3 × 12 = 36 min")
        let calmer = headline(world, stuckFactor: 5).title
        #expect(calmer.situation == .buildRunning, "48 min against 5 × 12 = 60 min is not stuck")
        #expect(calmer.text == "Brioche #412 is running.", "past its median, no end is promised")
    }

    @Test func aBuildNeedsThreeSamplesOfItsActionToBeCalledStuck() {
        var world = World()
        baseline(&world)
        product(&world, "pbri", "Brioche")
        workflow(&world, "wrelease", "Release – iOS", product: "pbri")
        for index in 0..<2 {
            run(&world, 400 + index, workflow: "wrelease", product: "pbri", at: date(10, 10 + index, 9), minutes: 12, action: ("Test – iOS", 12))
        }
        run(&world, 412, workflow: "wrelease", product: "pbri", at: now.addingTimeInterval(-48 * 60), status: nil, progress: .running, action: ("Test – iOS", 48))

        #expect(headline(world).title.situation == .buildRunning)
    }

    // MARK: - Slowdown

    @Test func aSlowdownNamesTheAppTheDayAndTheAction() {
        var world = World()
        baseline(&world)
        slowdown(&world)

        let title = headline(world).title

        #expect(title.text == "Brioche is slowing down since \(words().day(date(10, 7))).")
        #expect(title.emphasized == words().day(date(10, 7)))
        #expect(title.lead == "Test – iOS went from 6 min to 11 min since #397.")
        #expect(title.actions.map(\.action) == [.openBuild(runID: "wslow-397"), .openWorkflow(id: "wslow")])
    }

    // MARK: - Apple

    @Test func anOngoingIncidentThatCoversAStoppedBuildMakesTheHeadline() {
        var world = World()
        baseline(&world)
        apple(&world)

        let title = headline(world).title

        #expect(title.text == "Apple reports an incident on Xcode Cloud." && title.emphasized == "incident")
        #expect(title.lead?.hasPrefix("Since ") == true && title.lead?.contains("according to Apple’s system status page.") == true)
        #expect(title.lead?.hasSuffix("1 build stopped since.") == true)
        #expect(title.actions.map(\.action) == [.openAppleStatusPage])
    }

    @Test func anIncidentThatCoversNoStoppedBuildIsOnlyANoteAndAnExpiredReadingSaysNothing() {
        var world = World()
        baseline(&world)
        world.apple = AppleStatusKnowledge(events: [AppleStatusEvent(start: now.addingTimeInterval(-3600), end: nil)], readAt: now.addingTimeInterval(-60))

        let result = headline(world)
        #expect(result.title.situation == .allPassing)
        #expect(result.notes.map(\.kind) == [.apple])
        #expect(result.notes.first?.target == .appleStatusPage)

        world.apple = AppleStatusKnowledge(events: [AppleStatusEvent(start: now.addingTimeInterval(-3600), end: nil)], readAt: now.addingTimeInterval(-3600))
        #expect(headline(world).notes.isEmpty, "a page read an hour ago says nothing of now")

        world.apple = AppleStatusKnowledge(events: [AppleStatusEvent(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))], readAt: now)
        #expect(headline(world).notes.isEmpty, "a closed incident is not news")
    }

    // MARK: - Running, passing, reading

    @Test func aRunningBuildSaysWhenItEnds() throws {
        var world = World()
        baseline(&world)
        running(&world)

        let title = headline(world).title

        let end = date(10, 23, 14, 32).addingTimeInterval(-120 + 10 * 60)
        #expect(title.text == "Pollen #88 finishes around \(words().time(end)).")
        #expect(title.emphasized == words().time(end) && title.tone == .active)
        #expect(title.lead == "Test – iOS is running, ~8 min left (estimate).")
    }

    @Test func aRunningBuildWithoutEstimateIsJustRunningAndAQueuedOneWaits() {
        var world = World()
        baseline(&world)
        product(&world, "ppol", "Pollen")
        workflow(&world, "wpr", "PR checks", product: "ppol")
        run(&world, 88, workflow: "wpr", product: "ppol", at: now.addingTimeInterval(-120), status: nil, progress: .running)
        #expect(headline(world).title.text == "Pollen #88 is running.")

        world.runs = world.runs.filter { $0.id != "wpr-88" }
        run(&world, 89, workflow: "wpr", product: "ppol", at: now.addingTimeInterval(-60), status: nil, progress: .pending)
        #expect(headline(world).title.text == "Pollen #89 is waiting in the queue.")
    }

    @Test func otherBuildsAreMentionedInTheLead() {
        var world = World()
        baseline(&world)
        running(&world)
        run(&world, 89, workflow: "wpr", product: "ppol", at: now.addingTimeInterval(-60), status: nil, progress: .pending)
        #expect(headline(world).title.lead?.hasSuffix("Pollen #89 is waiting in the queue.") == true)

        run(&world, 90, workflow: "wpr", product: "ppol", at: now.addingTimeInterval(-30), status: nil, progress: .pending)
        #expect(headline(world).title.lead?.hasSuffix("2 more builds are running or queued.") == true)
    }

    @Test func everythingPassingCountsDaysSinceTheLastFailureAndTheWeek() {
        var world = World()
        baseline(&world)
        product(&world, "psext", "Sextant")
        workflow(&world, "wnightly", "Nightly", product: "psext")
        run(&world, 1, workflow: "wnightly", product: "psext", at: date(10, 14, 2), status: .failed)
        run(&world, 2, workflow: "wnightly", product: "psext", at: date(10, 16, 2))

        let title = headline(world).title

        #expect(title.text == "Everything is passing for 9 days." && title.emphasized == "passing" && title.tone == .good)
        #expect(title.lead == "4 builds this week, 100% succeeded.", "the baseline's four builds; the success of the 16th is a day before the week")
    }

    @Test func everythingPassingWithoutAnyKnownFailureSaysOver() {
        var world = World()
        baseline(&world)

        #expect(headline(world).title.text == "Everything is passing for over 35 days.")
    }

    @Test func aFailureYesterdayOrTodayIsSaidShort() {
        var world = World()
        baseline(&world)
        product(&world, "psext", "Sextant")
        workflow(&world, "wnightly", "Nightly", product: "psext")
        run(&world, 1, workflow: "wnightly", product: "psext", at: date(10, 22, 2), status: .failed)
        run(&world, 2, workflow: "wnightly", product: "psext", at: date(10, 22, 9))
        #expect(headline(world).title.text == "Everything is passing since yesterday.")

        run(&world, 3, workflow: "wnightly", product: "psext", at: date(10, 23, 2), status: .failed)
        run(&world, 4, workflow: "wnightly", product: "psext", at: date(10, 23, 9))
        #expect(headline(world).title.text == "Everything is passing.")
    }

    @Test func withoutFinishedBuildsCumulusReadsTheBuilds() {
        let title = headline(World()).title

        #expect(title.text == "Cumulus is reading your builds." && title.emphasized == "reading" && title.tone == .neutral)
        #expect(title.lead == "The last 35 days are on their way; the mosaic fills in as they arrive.")
        #expect(title.actions.isEmpty)
    }

    // MARK: - Small notes

    @Test func theNotesFollowTheGravityOrderAndNeverExceedThree() {
        var world = World()
        baseline(&world)
        broken(&world)
        plan(&world)
        slowdown(&world)
        stuck(&world)
        apple(&world)

        let result = headline(world)

        #expect(result.title.situation == .broken)
        #expect(result.notes.map(\.kind) == [.plan, .stuck, .slowdown])
        #expect(result.notes.map(\.label) == ["Plan", "Stuck", "Slowdown"])
    }

    @Test func theNotesLeaveOutTheFactOfTheHeadline() {
        var world = World()
        baseline(&world)
        stuck(&world)
        slowdown(&world)

        let result = headline(world)

        #expect(result.title.situation == .stuckBuild)
        #expect(result.notes.map(\.kind) == [.slowdown])
        #expect(result.notes.first?.sentence == "Brioche · Test – iOS slowed down by 83% since #397.")
        #expect(result.notes.first?.detail == "Test – iOS went from 6 min to 11 min.")
        #expect(result.notes.first?.target == .workflow(id: "wslow"))
    }

    @Test func aPlanNoteSaysTheDayAndTheDistanceToTheReset() throws {
        var world = World()
        baseline(&world)
        broken(&world)
        plan(&world)
        let summary = try #require(world.summary)
        let exhaustion = try #require(summary.exhaustionDate)

        let note = try #require(headline(world).notes.first)

        #expect(note.kind == .plan && note.tone == .warning && note.target == nil)
        #expect(note.sentence.hasPrefix("Runs out around \(words().day(exhaustion)), ") && note.sentence.hasSuffix(" days before the reset (estimate)."))
    }

    @Test func testFlightNotesSayAReviewWaitingADayOrMoreAndAnExpiryUnderSevenDays() throws {
        var world = World()
        baseline(&world)
        product(&world, "pbri", "Brioche")
        product(&world, "ppol", "Pollen")
        var waiting = TestFlightFixture.build(id: "tf-412", member: [], internalState: .testing, external: .waitingForReview, now: now)
        waiting.review = .waiting
        waiting.reviewSubmittedDate = now.addingTimeInterval(-2 * 86_400 - 3600)
        var testing = TestFlightFixture.build(id: "tf-87", internalState: .testing, external: .testing, now: now)
        testing.buildNumber = "87"
        testing.marketingVersion = "2.1"
        testing.expirationDate = now.addingTimeInterval(4.5 * 86_400)
        world.testFlight = [
            "pbri": TestFlightReading(appID: "app-pbri", builds: [waiting], readAt: now),
            "ppol": TestFlightReading(appID: "app-ppol", builds: [testing], readAt: now),
        ]

        let notes = headline(world).notes

        #expect(notes.map(\.kind) == [.testFlight, .testFlight])
        #expect(notes.map(\.sentence) == [
            "Brioche 1.4 (412) has been waiting for Apple’s beta review for 2 days.",
            "Pollen 2.1 (87): the latest build for external testers expires in 5 days.",
        ])
        #expect(notes.map(\.target) == [.app(productID: "pbri"), .app(productID: "ppol")])

        waiting.reviewSubmittedDate = now.addingTimeInterval(-20 * 3600)
        testing.expirationDate = now.addingTimeInterval(8 * 86_400)
        world.testFlight = ["pbri": TestFlightReading(appID: "app-pbri", builds: [waiting], readAt: now), "ppol": TestFlightReading(appID: "app-ppol", builds: [testing], readAt: now)]
        #expect(headline(world).notes.isEmpty, "under a day waiting, and more than a week to expire")
    }

    @Test func flakyTestsAndAnOldXcodeAreNotes() throws {
        var world = World()
        baseline(&world)
        world.workflows[0].xcodeVersion = "26.4"
        world.workflows[0].xcodeVersionName = "Xcode 26.4"
        world.xcodeVersions = [CIXcodeVersion(id: "x1", name: "Xcode 27.1", version: "27.1"), CIXcodeVersion(id: "x2", name: "Xcode 27.2 beta 2", version: "27.2")]
        world.flaky = [OverviewFlakyTests.Entry(workflowID: "wbase", tests: ["CheckoutTests/testApplePaySheet", "CartTests/testBadgeCount", "A/b"])]

        let notes = headline(world).notes

        #expect(notes.map(\.kind) == [.flakyTests, .xcode])
        #expect(notes[0].sentence == "Base · Main has 3 flaky tests.")
        #expect(notes[0].detail == "CheckoutTests/testApplePaySheet and CartTests/testBadgeCount, +1 more.")
        #expect(notes[0].target == .workflow(id: "wbase"))
        #expect(notes[1].sentence == "Base · Main uses Xcode 26.4; Xcode 27.1 is available.")
    }

    @Test func aWorkflowWithTheMostFlakyTestsIsTheOneNoted() {
        var world = World()
        baseline(&world)
        product(&world, "ppol", "Pollen")
        workflow(&world, "wpr", "PR checks", product: "ppol")
        run(&world, 1, workflow: "wpr", product: "ppol", at: date(10, 22, 9))
        world.flaky = [OverviewFlakyTests.Entry(workflowID: "wbase", tests: ["A/a"]), OverviewFlakyTests.Entry(workflowID: "wpr", tests: ["B/b", "C/c"])]

        #expect(headline(world).notes.first?.sentence == "Pollen · PR checks has 2 flaky tests.")
    }

    // MARK: - Pro

    @Test func aFactFromAProFunctionDoesNotExistWithoutPro() {
        var world = World()
        baseline(&world)
        stuck(&world)
        slowdown(&world)
        world.workflows[0].xcodeVersion = "26.4"
        world.flaky = [OverviewFlakyTests.Entry(workflowID: "wbase", tests: ["A/a"])]
        var waiting = TestFlightFixture.build(id: "tf-1", member: [], external: .waitingForReview, now: now)
        waiting.review = .waiting
        waiting.reviewSubmittedDate = now.addingTimeInterval(-3 * 86_400)
        world.testFlight = ["pbase": TestFlightReading(appID: "app-pbase", builds: [waiting], readAt: now)]

        #expect(headline(world).title.situation == .stuckBuild)
        #expect(Set(headline(world).notes.map(\.kind)) == [.slowdown, .testFlight, .flakyTests])

        world.pro = []
        let free = headline(world)
        #expect(free.title.situation == .buildRunning, "neither stuck nor slowed down without Pro")
        #expect(free.notes.isEmpty)
    }

    @Test func eachProFunctionOpensOnlyItsOwnFact() {
        func kinds(without feature: ProFeature) -> Set<OverviewHeadline.Note.Kind> {
            var world = World()
            baseline(&world)
            slowdown(&world)
            world.flaky = [OverviewFlakyTests.Entry(workflowID: "wbase", tests: ["A/a"])]
            var waiting = TestFlightFixture.build(id: "tf-1", member: [], external: .waitingForReview, now: now)
            waiting.review = .waiting
            waiting.reviewSubmittedDate = now.addingTimeInterval(-3 * 86_400)
            world.testFlight = ["pbase": TestFlightReading(appID: "app-pbase", builds: [waiting], readAt: now)]
            world.pro.remove(feature)
            let result = headline(world)
            return Set(result.notes.map(\.kind)).union(result.title.situation == .slowdown ? [.slowdown] : [])
        }

        #expect(kinds(without: .workflowTrends) == [.testFlight, .flakyTests])
        #expect(kinds(without: .testFlightTracking) == [.slowdown, .flakyTests])
        #expect(kinds(without: .testHealth) == [.slowdown, .testFlight])
    }

    // MARK: - Words

    @Test func emphasisIsWhatSitsBetweenDoubleAsterisks() {
        let parts = OverviewHeadlineWords.parts(of: "Sextant has been **broken** for two days.")

        #expect(parts == [
            OverviewHeadline.Part(text: "Sextant has been ", isEmphasized: false), OverviewHeadline.Part(text: "broken", isEmphasized: true),
            OverviewHeadline.Part(text: " for two days.", isEmphasized: false),
        ])
        #expect(OverviewHeadlineWords.parts(of: "**All**") == [OverviewHeadline.Part(text: "All", isEmphasized: true)])
        #expect(OverviewHeadlineWords.parts(of: "Plain") == [OverviewHeadline.Part(text: "Plain", isEmphasized: false)])
    }

    @Test func aNameCannotOpenAnEmphasis() {
        var world = World()
        product(&world, "pa", "Odd**App")
        workflow(&world, "w", "Main", product: "pa")
        run(&world, 1, workflow: "w", product: "pa", at: date(10, 22, 20), status: .failed)

        let title = headline(world).title

        #expect(title.text == "OddApp has been broken since yesterday." && title.emphasized == "broken")
    }

    @Test func theHeadlineIsOneFactInThePresentWithoutExclamationMark() {
        for (_, apply) in scenes {
            var world = World()
            baseline(&world)
            apply(&world)
            let result = headline(world)
            #expect(!result.title.text.contains("!"))
            #expect(!result.title.parts.isEmpty && result.title.text.hasSuffix("."))
            #expect(result.notes.allSatisfy { !$0.sentence.contains("!") })
        }
    }

    // MARK: - French

    @Test func theBrokenHeadlineReadsInFrench() {
        var world = World()
        baseline(&world)
        broken(&world)
        world.insights = ["wnightly-205": "Quatre tests tombent depuis iOS 27."]

        let title = headline(world, locale: french).title

        #expect(title.text == "Sextant est cassé depuis deux jours.")
        #expect(title.emphasized == "cassé")
        #expect(title.lead == "Nightly échoue depuis #203, trois fois de suite. Quatre tests tombent depuis iOS 27.")
        #expect(title.actions.map(\.title) == ["Ouvrir #205", "Copier pour une IA"])
    }

    @Test func theOtherHeadlinesReadInFrench() throws {
        var plan = World()
        baseline(&plan)
        self.plan(&plan)
        let exhaustion = try #require(plan.summary?.exhaustionDate)
        let day = words(french).day(exhaustion)
        #expect(headline(plan, locale: french).title.text == "Le forfait sera épuisé le \(day).")
        #expect(headline(plan, locale: french).title.lead?.hasSuffix("jours avant la réinitialisation, au rythme de ce cycle. Estimation.") == true)

        var stuck = World()
        baseline(&stuck)
        self.stuck(&stuck)
        #expect(headline(stuck, locale: french).title.text == "Brioche #412 tourne depuis 48\u{a0}min.")
        #expect(headline(stuck, locale: french).title.lead == "D’habitude, Release – iOS finit en 12\u{a0}min.")

        var passing = World()
        baseline(&passing)
        product(&passing, "psext", "Sextant")
        workflow(&passing, "wnightly", "Nightly", product: "psext")
        run(&passing, 1, workflow: "wnightly", product: "psext", at: date(10, 14, 2), status: .failed)
        run(&passing, 2, workflow: "wnightly", product: "psext", at: date(10, 16, 2))
        #expect(headline(passing, locale: french).title.text == "Tout passe depuis 9 jours.")
        #expect(headline(passing, locale: french).title.lead?.hasPrefix("4 builds cette semaine, 100") == true)

        #expect(headline(World(), locale: french).title.text == "Cumulus lit vos builds.")
    }

    @Test func countsAgreeInBothLanguages() {
        let english = words(english)
        let french = words(french)

        #expect(english.flakyTests(app: "A", workflow: "B", count: 1) == "A · B has 1 flaky test.")
        #expect(english.flakyTests(app: "A", workflow: "B", count: 2) == "A · B has 2 flaky tests.")
        #expect(french.flakyTests(app: "A", workflow: "B", count: 1) == "A · B compte 1 test instable.")
        #expect(french.flakyTests(app: "A", workflow: "B", count: 3) == "A · B compte 3 tests instables.")
        #expect(english.beforeReset(days: 1) == "1 day before the reset" && english.beforeReset(days: 0) == "Just before the reset")
        #expect(french.beforeReset(days: 1) == "1 jour avant la réinitialisation" && french.beforeReset(days: 3) == "3 jours avant la réinitialisation")
        #expect(english.forDays(1) == "for 1 day" && french.forDays(1) == "depuis 1 jour" && french.forDays(4) == "depuis 4 jours")
        #expect(french.spelled(3) == "trois" && english.spelled(3) == "three" && english.spelled(12) == "12")
        #expect(english.moreBuilds(1) == "1 more build is running or queued." && french.moreBuilds(2) == "2 autres builds sont en cours ou en file.")
    }

    @Test func labelsAndTypographyAreTranslated() {
        let french = words(french)

        #expect(OverviewHeadline.Note.Kind.allCases.map { french.label($0) } == ["Cassé", "Forfait", "Bloqué", "Ralentissement", "TestFlight", "Tests instables", "Xcode", "Apple"])
        #expect(OverviewHeadline.Note.Kind.allCases.map { words().label($0) } == ["Broken", "Plan", "Stuck", "Slowdown", "TestFlight", "Flaky tests", "Xcode", "Apple"])
    }

    // MARK: - The flaky reader

    @Test func aWorkflowEntryListsItsFlakyTestsOrNothing() {
        func sample(_ number: Int, status: CITestStatus, commit: String) -> TestHealthReport.Sample {
            TestHealthReport.Sample(
                runID: "r\(number)", number: number, date: nil, commit: commit,
                tests: [TestHealthReport.Observation(actionName: "Test", className: "CartTests", name: "testBadge", status: status)]
            )
        }
        let flaky = TestHealthReport(samples: [sample(1, status: .success, commit: "abc"), sample(2, status: .failure, commit: "abc")], eligibleBuilds: 2)
        let steady = TestHealthReport(samples: [sample(1, status: .success, commit: "abc"), sample(2, status: .success, commit: "def")], eligibleBuilds: 2)

        #expect(OverviewFlakyTests.entry(workflowID: "w", report: flaky) == OverviewFlakyTests.Entry(workflowID: "w", tests: ["CartTests/testBadge"]))
        #expect(OverviewFlakyTests.entry(workflowID: "w", report: steady) == nil)
    }
}
