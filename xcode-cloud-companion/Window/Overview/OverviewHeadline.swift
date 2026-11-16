import Foundation

/// The top of the Overview: one headline that says the most important true thing, its lead and its buttons, and up to
/// three small notes with the other facts. Pure: it reads what the app already holds, handed in as `Facts`, and asks
/// Apple for nothing and generates nothing.
///
/// The headline is the highest of these that applies:
/// 1. a workflow is broken; 2. the plan runs out before the cycle ends; 3. a build is stuck;
/// 4. a workflow slowed down; 5. an Apple incident covers a build that stopped; 6. a build is running;
/// 7. everything passes; 8. nothing has been read yet.
nonisolated struct OverviewHeadline: Equatable, Sendable {
    /// How many small notes the screen shows.
    static let maximumNotes = 3
    /// A TestFlight build waiting for its beta review this long, or longer, is worth a note.
    static let reviewWaitMinimum: TimeInterval = 86_400
    /// The build testers are on, this close to expiring, is worth a note: the same lead as the banner.
    static let expiryLead: TimeInterval = TestFlightAlertPlanner.expiryLead

    /// The situations, from the one that wins to the one that gives way.
    enum Situation: Int, CaseIterable, Comparable, Sendable {
        case broken, planRunsOut, stuckBuild, slowdown, appleIncident, buildRunning, allPassing, reading

        static func < (lhs: Situation, rhs: Situation) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The colour of the state the headline speaks of.
    enum Tone: Equatable, Sendable {
        case alert, warning, active, good, neutral
    }

    /// A piece of a sentence; the emphasized one is drawn in the tone's colour.
    struct Part: Equatable, Sendable {
        let text: String
        let isEmphasized: Bool
    }

    /// Where a click leads.
    enum Target: Equatable, Sendable {
        case build(runID: String)
        case workflow(id: String)
        case app(productID: String)
        case appleStatusPage
    }

    enum Action: Equatable, Sendable {
        case openBuild(runID: String)
        case copyForAI(runID: String)
        case openWorkflow(id: String)
        case openAppleStatusPage
    }

    /// A button under the headline: what it does and what it says.
    struct Choice: Equatable, Sendable {
        let action: Action
        let title: String
    }

    struct Title: Equatable, Sendable {
        let situation: Situation
        let parts: [Part]
        let tone: Tone
        /// The lead under the headline; nil when there is nothing more to say.
        let lead: String?
        let actions: [Choice]

        var text: String { parts.map(\.text).joined() }
        var emphasized: String { parts.filter(\.isEmphasized).map(\.text).joined() }
    }

    /// A fact other than the headline's, ranked by how serious it is.
    struct Note: Identifiable, Equatable, Sendable {
        /// In the order the notes are ranked.
        enum Kind: Int, CaseIterable, Comparable, Sendable {
            case broken, plan, stuck, slowdown, testFlight, flakyTests, xcode, apple

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let id: String
        let kind: Kind
        /// The label above the sentence.
        let label: String
        let tone: Tone
        let sentence: String
        /// The grey line under the sentence.
        let detail: String?
        /// Nil when a click leads nowhere.
        let target: Target?
    }

    let title: Title
    let notes: [Note]

    /// What the app already knows.
    struct Facts: Sendable {
        var snapshot: BuildSnapshot
        var mosaic: OverviewMosaic
        /// Nil without a plan.
        var summary: UsageSummary?
        var ledger = UsageLedger()
        var now: Date
        var calendar = Calendar.current
        var locale = Locale.autoupdatingCurrent
        /// The sentence of “In brief” already in the cache, by build; only read while it is open (the model, the setting).
        var failureInsights: [String: String] = [:]
        var appleStatus: AppleStatusKnowledge?
        /// The last reading of each app’s TestFlight builds, by Xcode Cloud product.
        var testFlight: [String: TestFlightReading] = [:]
        /// The flaky tests already read from the build details (`OverviewFlakyTests.read`).
        var flakyTests: [OverviewFlakyTests.Entry] = []
        var stuckFactor = BuildNotificationRules.defaultStuckFactor

        init(snapshot: BuildSnapshot, mosaic: OverviewMosaic, summary: UsageSummary? = nil, now: Date) {
            self.snapshot = snapshot
            self.mosaic = mosaic
            self.summary = summary
            self.now = now
        }
    }

    init(_ facts: Facts) {
        let composer = Composer(facts)
        title = composer.title()
        notes = composer.notes(excluding: title.situation)
    }

    // MARK: - Composing

    private struct Composer {
        let facts: Facts
        let words: OverviewHeadlineWords
        let rows: [Row]
        let broken: [Broken]
        let planFact: Plan?
        let stuckBuilds: [Stuck]
        let slowdowns: [OverviewSlowdownFact]
        let apple: Apple?

        /// A mosaic row with the app it belongs to.
        struct Row {
            let appName: String
            let row: OverviewMosaic.Row
        }

        struct Broken {
            let appName: String
            let row: OverviewMosaic.Row
            let series: OverviewMosaic.FailureSeries
        }

        struct Plan {
            let summary: UsageSummary
            /// Nil when the plan is already spent.
            let exhaustion: Date?
        }

        struct Stuck {
            let run: CIBuildRun
            let appName: String
            let overrun: BuildNotificationPlanner.Overrun
            /// Seconds since the build started.
            let elapsed: TimeInterval
            let workflowMedian: TimeInterval?
        }

        struct Apple {
            let event: AppleStatusEvent
            let stoppedBuilds: Int
        }

        init(_ facts: Facts) {
            self.facts = facts
            words = OverviewHeadlineWords(locale: facts.locale, calendar: facts.calendar)
            rows = facts.mosaic.groups.flatMap { group in group.rows.map { Row(appName: group.name, row: $0) } }
            broken = Self.brokenWorkflows(rows)
            planFact = Self.plan(facts)
            stuckBuilds = Self.stuck(facts)
            slowdowns = OverviewSlowdownFact.all(facts: facts, rows: rows.map { ($0.appName, $0.row) })
            apple = Self.apple(facts)
        }

        // MARK: Facts

        /// Worst first: the longest run of failures, then the oldest.
        static func brokenWorkflows(_ rows: [Row]) -> [Broken] {
            rows.compactMap { entry -> Broken? in
                guard !entry.row.isPaused, let series = entry.row.failureSeries else { return nil }
                return Broken(appName: entry.appName, row: entry.row, series: series)
            }
            .enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.series, rhs.element.series)
                if left.failureCount != right.failureCount { return left.failureCount > right.failureCount }
                if left.firstDate != right.firstDate { return (left.firstDate ?? .distantFuture) < (right.firstDate ?? .distantFuture) }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        }

        static func plan(_ facts: Facts) -> Plan? {
            guard let summary = facts.summary, summary.quotaMinutes > 0, !summary.measurement.isMeasuring else { return nil }
            if summary.usedMinutes >= summary.quotaMinutes { return Plan(summary: summary, exhaustion: nil) }
            guard let exhaustion = summary.exhaustionDate else { return nil }
            return Plan(summary: summary, exhaustion: exhaustion)
        }

        /// The builds the stuck-build banner would report, the furthest past their usual first.
        static func stuck(_ facts: Facts) -> [Stuck] {
            let snapshot = facts.snapshot
            return snapshot.runs.compactMap { run -> (Stuck, Double)? in
                guard let overrun = BuildNotificationPlanner.overrun(of: run, in: snapshot, factor: facts.stuckFactor, now: facts.now) else { return nil }
                let median = run.workflowID.flatMap { id in WorkflowTrends(runs: snapshot.runs.filter { $0.workflowID == id }).medianDuration }
                let started = run.startedDate ?? run.createdDate ?? overrun.action.startedDate
                let elapsed = started.map { facts.now.timeIntervalSince($0) } ?? overrun.elapsed
                let stuck = Stuck(
                    run: run, appName: snapshot.product(id: run.productID)?.displayName ?? "", overrun: overrun, elapsed: max(elapsed, overrun.elapsed),
                    workflowMedian: median
                )
                return (stuck, overrun.elapsed / overrun.usual)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }

        static func apple(_ facts: Facts) -> Apple? {
            guard let knowledge = facts.appleStatus, let event = knowledge.ongoing(at: facts.now) else { return nil }
            let stopped = facts.snapshot.runs.filter { run in
                guard AppleStatusSchedule.isErrored(run), let start = run.startedDate ?? run.createdDate, let end = run.finishedDate else { return false }
                return event.covers(from: start, to: end, now: facts.now)
            }.count
            return Apple(event: event, stoppedBuilds: stopped)
        }

        // MARK: Title

        func title() -> Title {
            if let title = brokenTitle() { return title }
            if let title = planTitle() { return title }
            if let title = stuckTitle() { return title }
            if let title = slowdownTitle() { return title }
            if let title = appleTitle() { return title }
            if let title = runningTitle() { return title }
            if let title = passingTitle() { return title }
            return Title(
                situation: .reading, parts: OverviewHeadlineWords.parts(of: words.reading()), tone: .neutral,
                lead: words.readingLine(days: facts.mosaic.days.count), actions: []
            )
        }

        private func brokenTitle() -> Title? {
            guard let worst = broken.first else { return nil }
            let appIDs = Set(broken.map(\.row.productID))
            let inWorstApp = broken.filter { $0.row.productID == worst.row.productID }
            let marked: String
            if appIDs.count >= 2 {
                marked = words.brokenApps(count: appIDs.count)
            } else if inWorstApp.count >= 2 {
                marked = words.brokenWorkflows(app: worst.appName)
            } else {
                marked = words.broken(app: worst.appName, since: worst.series.firstDate.map { words.span(since: $0, now: facts.now) })
            }
            // With several apps the headline does not name one, so the lead does.
            let name = appIDs.count >= 2 ? "\(worst.appName) · \(worst.row.name)" : worst.row.name
            var lead = [words.failureLine(workflow: name, series: worst.series)]
            if let sentence = insight(for: worst.series) { lead.append(sentence) }
            return Title(
                situation: .broken, parts: OverviewHeadlineWords.parts(of: marked), tone: .alert, lead: lead.joined(separator: " "),
                actions: [
                    Choice(action: .openBuild(runID: worst.series.lastRunID), title: words.openBuild(number: worst.series.lastNumber)),
                    Choice(action: .copyForAI(runID: worst.series.lastRunID), title: words.copyForAI()),
                ]
            )
        }

        private func planTitle() -> Title? {
            guard let plan = planFact else { return nil }
            guard let exhaustion = plan.exhaustion else {
                return Title(
                    situation: .planRunsOut, parts: OverviewHeadlineWords.parts(of: words.planUsedUp()), tone: .alert,
                    lead: words.resetsOn(plan.summary.resetDate), actions: []
                )
            }
            return Title(
                situation: .planRunsOut, parts: OverviewHeadlineWords.parts(of: words.planRunsOut(on: exhaustion)), tone: .warning,
                lead: words.planPaceLine(daysBeforeReset: daysBeforeReset(exhaustion, plan.summary)), actions: []
            )
        }

        private func stuckTitle() -> Title? {
            guard let stuck = stuckBuilds.first else { return nil }
            let usual: String
            if let median = stuck.workflowMedian, let workflow = stuck.run.workflowName {
                usual = words.usualWorkflow(workflow, usual: median)
            } else {
                usual = words.usualAction(BuildDetailModel.name(of: stuck.overrun.action), usual: stuck.overrun.usual)
            }
            return Title(
                situation: .stuckBuild, parts: OverviewHeadlineWords.parts(of: words.stuck(build: buildName(stuck.run, app: stuck.appName), elapsed: stuck.elapsed)),
                tone: .warning, lead: usual, actions: [Choice(action: .openBuild(runID: stuck.run.id), title: words.openBuild(number: stuck.run.number))]
            )
        }

        private func slowdownTitle() -> Title? {
            guard let slowdown = slowdowns.first else { return nil }
            return Title(
                situation: .slowdown,
                parts: OverviewHeadlineWords.parts(of: words.slowdown(app: slowdown.appName, since: slowdown.model.since ?? facts.now)),
                tone: .warning, lead: words.slowdownLine(slowdown.model, build: slowdown.model.run.number),
                actions: [
                    Choice(action: .openBuild(runID: slowdown.model.run.id), title: words.openBuild(number: slowdown.model.run.number)),
                    Choice(action: .openWorkflow(id: slowdown.workflowID), title: words.openWorkflow()),
                ]
            )
        }

        private func appleTitle() -> Title? {
            guard let apple, apple.stoppedBuilds > 0 else { return nil }
            return Title(
                situation: .appleIncident, parts: OverviewHeadlineWords.parts(of: words.appleIncident()), tone: .warning,
                lead: words.appleLine(since: apple.event.start, now: facts.now, stoppedBuilds: apple.stoppedBuilds),
                actions: [Choice(action: .openAppleStatusPage, title: words.openStatusPage())]
            )
        }

        private func runningTitle() -> Title? {
            let entries = RunningBuildsETA.entries(in: facts.snapshot, now: facts.now)
            guard let first = entries.first else { return nil }
            let name = buildName(first.run, app: facts.snapshot.product(id: first.run.productID)?.displayName ?? "")
            let display = first.eta?.display(at: facts.now)
            let marked: String
            if first.run.executionProgress == .pending {
                marked = words.queued(build: name)
            } else if let eta = first.eta, display != nil {
                marked = words.runningEnds(build: name, at: eta.expectedEnd)
            } else {
                marked = words.running(build: name)
            }
            var lead: [String] = []
            if first.run.executionProgress == .running, let line = words.runningLine(action: currentAction(of: first.run), remaining: display) {
                lead.append(line)
            }
            let others = Array(entries.dropFirst())
            if others.count == 1, let other = others.first {
                let otherName = buildName(other.run, app: facts.snapshot.product(id: other.run.productID)?.displayName ?? "")
                lead.append(other.run.executionProgress == .pending ? words.alsoQueued(build: otherName) : words.alsoRunning(build: otherName))
            } else if others.count > 1 {
                lead.append(words.moreBuilds(others.count))
            }
            return Title(
                situation: .buildRunning, parts: OverviewHeadlineWords.parts(of: marked), tone: .active, lead: lead.isEmpty ? nil : lead.joined(separator: " "),
                actions: [Choice(action: .openBuild(runID: first.run.id), title: words.openBuild(number: first.run.number))]
            )
        }

        private func passingTitle() -> Title? {
            let snapshot = facts.snapshot
            guard snapshot.runs.contains(where: { $0.executionProgress == .complete }) else { return nil }
            let today = facts.calendar.startOfDay(for: facts.now)
            let lastFailure = snapshot.runs
                .filter { $0.executionProgress == .complete && ($0.completionStatus == .failed || $0.completionStatus == .errored) }
                .compactMap { run in (run.createdDate ?? run.startedDate).flatMap { $0 <= facts.now ? $0 : nil } }
                .max()
            let span: String?
            if let lastFailure {
                let days = facts.calendar.dateComponents([.day], from: facts.calendar.startOfDay(for: lastFailure), to: today).day ?? 0
                span = words.passingSpan(days: days, isAtLeast: false)
            } else {
                span = words.passingSpan(days: facts.mosaic.days.count, isAtLeast: true)
            }
            let week = facts.mosaic.rows.flatMap { $0.cells.suffix(OverviewMosaic.recentDays) }
            let succeeded = week.reduce(0) { $0 + $1.succeeded }
            let failed = week.reduce(0) { $0 + $1.failed }
            let rate = succeeded + failed > 0 ? Double(succeeded) / Double(succeeded + failed) : nil
            return Title(
                situation: .allPassing, parts: OverviewHeadlineWords.parts(of: words.passing(since: span)), tone: .good,
                lead: words.weekLine(builds: week.reduce(0) { $0 + $1.builds }, successRate: rate), actions: []
            )
        }

        // MARK: Notes

        func notes(excluding situation: Situation) -> [Note] {
            var notes: [Note] = []
            notes += brokenNotes(skippingFirst: situation == .broken)
            notes += planNotes(skipping: situation == .planRunsOut)
            notes += stuckNotes(skippingFirst: situation == .stuckBuild)
            notes += slowdownNotes(skippingFirst: situation == .slowdown)
            notes += testFlightNotes()
            notes += flakyNotes()
            notes += xcodeNotes()
            notes += appleNotes(skipping: situation == .appleIncident)
            let ranked = notes.enumerated().sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            return Array(ranked.map(\.element).prefix(OverviewHeadline.maximumNotes))
        }

        private func brokenNotes(skippingFirst: Bool) -> [Note] {
            // The headline and its lead tell about the worst workflow; every other broken one is a note.
            broken.dropFirst(skippingFirst ? 1 : 0).map { entry in
                Note(
                    id: "broken-\(entry.row.workflowID)", kind: .broken, label: words.label(.broken), tone: .alert,
                    sentence: words.failureLine(workflow: "\(entry.appName) · \(entry.row.name)", series: entry.series),
                    detail: insight(for: entry.series), target: .build(runID: entry.series.lastRunID)
                )
            }
        }

        private func planNotes(skipping: Bool) -> [Note] {
            guard !skipping, let plan = planFact else { return [] }
            let sentence: String
            if let exhaustion = plan.exhaustion {
                sentence = words.planNote(on: exhaustion, daysBeforeReset: daysBeforeReset(exhaustion, plan.summary))
            } else {
                sentence = words.planUsedUpNote(resetting: plan.summary.resetDate)
            }
            return [Note(
                id: "plan", kind: .plan, label: words.label(.plan), tone: plan.exhaustion == nil ? .alert : .warning, sentence: sentence, detail: nil, target: nil
            )]
        }

        private func stuckNotes(skippingFirst: Bool) -> [Note] {
            stuckBuilds.dropFirst(skippingFirst ? 1 : 0).map { stuck in
                Note(
                    id: "stuck-\(stuck.run.id)", kind: .stuck, label: words.label(.stuck), tone: .warning,
                    sentence: words.stuckNote(build: buildName(stuck.run, app: stuck.appName), elapsed: stuck.elapsed),
                    detail: stuck.workflowMedian.flatMap { median in stuck.run.workflowName.map { words.usualWorkflow($0, usual: median) } }
                        ?? words.usualAction(BuildDetailModel.name(of: stuck.overrun.action), usual: stuck.overrun.usual),
                    target: .build(runID: stuck.run.id)
                )
            }
        }

        private func slowdownNotes(skippingFirst: Bool) -> [Note] {
            slowdowns.dropFirst(skippingFirst ? 1 : 0).map { slowdown in
                Note(
                    id: "slowdown-\(slowdown.workflowID)", kind: .slowdown, label: words.label(.slowdown), tone: .warning,
                    sentence: words.slowdownNote(
                        app: slowdown.appName, workflow: slowdown.workflowName, increase: slowdown.model.slowdown.increase, build: slowdown.model.run.number
                    ),
                    detail: words.slowdownDetail(slowdown.model), target: .workflow(id: slowdown.workflowID)
                )
            }
        }

        private func testFlightNotes() -> [Note] {
            let order = Dictionary(facts.mosaic.groups.enumerated().map { ($0.element.productID, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let readings = facts.testFlight.sorted { lhs, rhs in
                (order[lhs.key] ?? Int.max, lhs.key) < (order[rhs.key] ?? Int.max, rhs.key)
            }
            var waiting: [Note] = []
            var expiring: [Note] = []
            for (productID, reading) in readings {
                let app = facts.snapshot.product(id: productID)?.displayName ?? productID
                let now = facts.now
                let review = reading.builds
                    .filter { build in
                        build.status(at: now) == .waitingForReview && (build.reviewSubmittedDate.map { now.timeIntervalSince($0) >= OverviewHeadline.reviewWaitMinimum } ?? false)
                    }
                    .max { ($0.uploadedDate ?? .distantPast) < ($1.uploadedDate ?? .distantPast) }
                if let review, let submitted = review.reviewSubmittedDate {
                    waiting.append(Note(
                        id: "testflight-review-\(review.id)", kind: .testFlight, label: words.label(.testFlight), tone: .warning,
                        sentence: words.testFlightWaiting(app: app, build: review.label, days: Int(now.timeIntervalSince(submitted) / 86_400)),
                        detail: nil, target: .app(productID: productID)
                    ))
                }
                let latest = reading.builds
                    .filter { $0.isAvailableToExternalTesters(at: now) }
                    .max { ($0.uploadedDate ?? .distantPast) < ($1.uploadedDate ?? .distantPast) }
                if let latest, let expiration = latest.expirationDate, expiration > now, expiration.timeIntervalSince(now) <= OverviewHeadline.expiryLead,
                   let days = latest.daysLeft(at: now) {
                    expiring.append(Note(
                        id: "testflight-expiry-\(latest.id)", kind: .testFlight, label: words.label(.testFlight), tone: .warning,
                        sentence: words.testFlightExpiry(app: app, build: latest.label, days: days), detail: nil, target: .app(productID: productID)
                    ))
                }
            }
            return waiting + expiring
        }

        private func flakyNotes() -> [Note] {
            let order = Dictionary(rows.enumerated().map { ($0.element.row.workflowID, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let best = facts.flakyTests
                .filter { order[$0.workflowID] != nil && !$0.tests.isEmpty }
                .min { lhs, rhs in
                    lhs.tests.count != rhs.tests.count ? lhs.tests.count > rhs.tests.count : (order[lhs.workflowID] ?? 0) < (order[rhs.workflowID] ?? 0)
                }
            guard let best, let entry = rows.first(where: { $0.row.workflowID == best.workflowID }) else { return [] }
            return [Note(
                id: "flaky-\(best.workflowID)", kind: .flakyTests, label: words.label(.flakyTests), tone: .warning,
                sentence: words.flakyTests(app: entry.appName, workflow: entry.row.name, count: best.tests.count),
                detail: words.flakyDetail(names: best.tests), target: .workflow(id: best.workflowID)
            )]
        }

        private func xcodeNotes() -> [Note] {
            let outdated = rows.compactMap { entry -> (Row, XcodeVersionCheck.Warning)? in
                guard !entry.row.isPaused, let workflow = facts.snapshot.workflow(id: entry.row.workflowID),
                      let warning = XcodeVersionCheck.warning(version: workflow.xcodeVersion, name: workflow.xcodeVersionName, among: facts.snapshot.xcodeVersions)
                else { return nil }
                return (entry, warning)
            }
            guard let (entry, warning) = outdated.first else { return [] }
            return [Note(
                id: "xcode-\(entry.row.workflowID)", kind: .xcode, label: words.label(.xcode), tone: .neutral,
                sentence: words.xcodeOutdated(app: entry.appName, workflow: entry.row.name, current: warning.current, latest: warning.latest),
                detail: outdated.count > 1 ? words.otherXcodeWorkflows(outdated.count - 1) : nil, target: .workflow(id: entry.row.workflowID)
            )]
        }

        private func appleNotes(skipping: Bool) -> [Note] {
            guard !skipping, let apple else { return [] }
            return [Note(
                id: "apple", kind: .apple, label: words.label(.apple), tone: .warning, sentence: words.appleNote(since: apple.event.start, now: facts.now),
                detail: words.appleSource(), target: .appleStatusPage
            )]
        }

        // MARK: Shared

        /// The sentence of “In brief” for a build that is already in the cache.
        private func insight(for series: OverviewMosaic.FailureSeries) -> String? {
            facts.failureInsights[series.lastRunID]?.nilIfBlank
        }

        private func buildName(_ run: CIBuildRun, app: String) -> String {
            [app.nilIfBlank, run.number.map { "#\($0)" }].compactMap(\.self).joined(separator: " ")
        }

        private func daysBeforeReset(_ exhaustion: Date, _ summary: UsageSummary) -> Int {
            let calendar = facts.calendar
            return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: exhaustion), to: calendar.startOfDay(for: summary.resetDate)).day ?? 0)
        }

        /// The action under way, as the menu says it.
        private func currentAction(of run: CIBuildRun) -> String? {
            (facts.snapshot.actionsByRunID[run.id] ?? [])
                .filter { $0.executionProgress == .running }
                .min { ($0.startedDate ?? .distantFuture) < ($1.startedDate ?? .distantFuture) }
                .map(BuildDetailModel.name(of:))
        }
    }
}

/// A slowed-down workflow with the app and workflow it belongs to.
nonisolated struct OverviewSlowdownFact: Sendable, Equatable {
    /// Models built with their cost line, for the ones the Overview can show.
    static let limit = OverviewHeadline.maximumNotes + 1

    let appName: String
    let workflowName: String
    let workflowID: String
    let model: WorkflowSlowdownModel

    /// The workflows that slowed down, the sharpest first; the cost line is worked out only for the few that can be shown.
    static func all(facts: OverviewHeadline.Facts, rows: [(appName: String, row: OverviewMosaic.Row)]) -> [OverviewSlowdownFact] {
        let snapshot = facts.snapshot
        let found = rows.compactMap { entry -> (entry: (appName: String, row: OverviewMosaic.Row), slowdown: WorkflowSlowdown)? in
            guard !entry.row.isPaused else { return nil }
            let runs = snapshot.runs.filter { $0.workflowID == entry.row.workflowID }
            return WorkflowSlowdown(runs: runs, actionsByRunID: snapshot.actionsByRunID).map { (entry, $0) }
        }
        .enumerated()
        .sorted { lhs, rhs in
            lhs.element.slowdown.increase != rhs.element.slowdown.increase ? lhs.element.slowdown.increase > rhs.element.slowdown.increase : lhs.offset < rhs.offset
        }
        .prefix(limit)
        return found.compactMap { item in
            let (entry, _) = (item.element.entry, item.element.slowdown)
            return WorkflowSlowdownModel.make(
                workflowID: entry.row.workflowID, snapshot: snapshot, ledger: facts.ledger, summary: facts.summary, now: facts.now
            ).map { OverviewSlowdownFact(appName: entry.appName, workflowName: entry.row.name, workflowID: entry.row.workflowID, model: $0) }
        }
    }
}
