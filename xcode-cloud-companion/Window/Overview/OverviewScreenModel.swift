import Foundation

/// How wide the figure of the Overview draws: how many days of the mosaic fit, how far apart the squares are, and where
/// the small notes go. Worked out from the width of the column alone, so it is the same in a window and in a test.
nonisolated struct OverviewFigureLayout: Equatable, Sendable {
    /// How many days the mosaic can show, widest first. The model always reads 35.
    static let dayOptions = [35, 21, 14, 7]
    /// Distance between the left sides of two squares; a square is `cellGap` less.
    static let preferredPitch: CGFloat = 24
    static let minimumPitch: CGFloat = 20
    /// The gap between two squares.
    static let cellGap: CGFloat = 3
    static let rowHeight: CGFloat = 24
    /// Between the names and the squares, and between the squares and the figures at the end of a row.
    static let nameGap: CGFloat = 10
    static let figuresGap: CGFloat = 14
    static let successWidth: CGFloat = 46
    static let medianWidth: CGFloat = 70
    static let cycleWidth: CGFloat = 58
    static let columnGap: CGFloat = 4
    /// The room the notes need to stand beside the figure, and the gap between them.
    static let notesMinimumWidth: CGFloat = 280
    static let notesMaximumWidth: CGFloat = 360
    static let notesGap: CGFloat = 34

    enum NotesPlacement: Equatable, Sendable {
        case beside, below
    }

    let days: Int
    let pitch: CGFloat
    let nameWidth: CGFloat
    let showsCycle: Bool
    let notes: NotesPlacement

    var cellSide: CGFloat { pitch - Self.cellGap }
    var cellsWidth: CGFloat { pitch * CGFloat(days) - Self.cellGap }
    var figuresWidth: CGFloat { Self.figuresWidth(showsCycle: showsCycle) }
    /// Names, squares and figures, without the notes.
    var figureWidth: CGFloat { nameWidth + Self.nameGap + cellsWidth + Self.figuresGap + figuresWidth }

    static func figuresWidth(showsCycle: Bool) -> CGFloat {
        successWidth + columnGap + medianWidth + (showsCycle ? columnGap + cycleWidth : 0)
    }

    /// - Parameters:
    ///   - width: the room inside the margins.
    ///   - showsCycle: the last column, the minutes of the cycle, needs a plan.
    ///   - availableDays: the days the mosaic holds.
    ///   - hasNotes: whether any small note is there to place.
    static func make(width: CGFloat, showsCycle: Bool, availableDays: Int = 35, hasNotes: Bool) -> OverviewFigureLayout {
        let nameWidth: CGFloat = width >= 760 ? 138 : 112
        let fixed = nameWidth + nameGap + figuresGap + figuresWidth(showsCycle: showsCycle)
        let options = dayOptions.filter { $0 <= availableDays }
        for days in options {
            let pitch = ((width - fixed + cellGap) / CGFloat(days)).rounded(.down)
            if pitch >= minimumPitch {
                let chosen = min(pitch, preferredPitch)
                let widest = days == options.first
                let figure = fixed + chosen * CGFloat(days) - cellGap
                let room = width - figure - notesGap
                let beside = hasNotes && widest && chosen == preferredPitch && room >= notesMinimumWidth
                return OverviewFigureLayout(days: days, pitch: chosen, nameWidth: nameWidth, showsCycle: showsCycle, notes: beside ? .beside : .below)
            }
        }
        let days = options.last ?? availableDays
        let pitch = max(12, min(preferredPitch, ((width - fixed + cellGap) / CGFloat(max(days, 1))).rounded(.down)))
        return OverviewFigureLayout(days: days, pitch: pitch, nameWidth: nameWidth, showsCycle: showsCycle, notes: .below)
    }

    /// How many columns the notes take below the figure: all side by side when each has room, one under another if not.
    static func noteColumns(count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        return width / CGFloat(count) >= 230 ? count : 1
    }
}

/// The line at the top of the Overview: the day, the account, what runs, and the plan.
nonisolated struct OverviewAccountLine: Equatable, Sendable {
    struct Running: Equatable, Sendable {
        let runID: String
        let text: String
    }

    enum Plan: Equatable, Sendable {
        /// `used` and `quota` are written out; the minutes are an estimate unless Apple billed them all.
        case set(used: String, quota: String, isEstimate: Bool)
        case missing
        case measuring
    }

    let day: String
    let time: String
    let account: String
    let running: Running?
    let plan: Plan

    init(
        snapshot: BuildSnapshot, summary: UsageSummary?, isMeasuring: Bool, accountName: String, now: Date,
        calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) {
        let words = OverviewScreenWords(locale: locale, calendar: calendar)
        day = words.longDay(now)
        time = words.time(now)
        account = accountName

        let entries = RunningBuildsETA.entries(in: snapshot, now: now)
        if let first = entries.first {
            let app = snapshot.product(id: first.run.productID)?.displayName
            let build = words.buildName(app: app, number: first.run.number)
            var text: String
            if first.run.executionProgress == .pending {
                text = words.queuedLine(build: build)
            } else if let eta = first.eta, let left = eta.display(at: now) {
                text = words.runningLine(build: build, end: eta.expectedEnd, left: left)
            } else {
                text = words.runningLine(build: build, end: nil, left: nil)
            }
            if entries.count > 1 { text = words.andMore(text, count: entries.count - 1) }
            running = Running(runID: first.run.id, text: text)
        } else {
            running = nil
        }

        if isMeasuring {
            plan = .measuring
        } else if let summary, summary.quotaMinutes > 0 {
            plan = .set(
                used: UsageFormat.minutes(summary.usedMinutes, locale: locale), quota: UsageFormat.minutes(summary.quotaMinutes, locale: locale),
                isEstimate: summary.estimatedMinutes > 0
            )
        } else {
            plan = .missing
        }
    }
}

/// Everything the Overview screen draws, worked out from what the app already holds: no request, no disk read.
nonisolated struct OverviewScreenModel: Sendable {
    enum Phase: Equatable, Sendable {
        /// The builds are being read or measured: a skeleton in place of the mosaic.
        case reading
        /// Nothing ran in the period the mosaic covers.
        case empty
        case ready
    }

    let phase: Phase
    let mosaic: OverviewMosaic
    let title: OverviewHeadline.Title
    let notes: [OverviewHeadline.Note]
    let accountLine: OverviewAccountLine
    /// Some of the minutes of the cycle are computed rather than billed.
    let hasEstimatedCycle: Bool
    /// What the bubble of a square and the drawer of a workflow read.
    let detail: OverviewDetailSource

    var showsCycle: Bool { mosaic.rows.contains { $0.cycle != nil } }

    /// - Parameters:
    ///   - isReading: the first sync or the first measure of the account is still going on.
    ///   - pro: the Cumulus Pro functions that are open; the facts that come from one are left out without it.
    ///   - failureInsights: the sentence of “In brief”, by build, already known and only while that function is open.
    ///   - failureCategories: the category of failed builds, by build, on the same terms.
    init(
        snapshot: BuildSnapshot, sidebar: SidebarContent, summary: UsageSummary?, ledger: UsageLedger = UsageLedger(), accountName: String,
        isReading: Bool, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent,
        pro: Set<ProFeature> = Set(ProFeature.allCases), failureInsights: [String: String] = [:],
        failureCategories: [String: FailureCategory] = [:], appleStatus: AppleStatusKnowledge? = nil,
        testFlight: [String: TestFlightReading] = [:], flakyTests: [OverviewFlakyTests.Entry] = []
    ) {
        let words = OverviewScreenWords(locale: locale, calendar: calendar)
        accountLine = OverviewAccountLine(
            snapshot: snapshot, summary: summary, isMeasuring: summary?.measurement.isMeasuring ?? false, accountName: accountName,
            now: now, calendar: calendar, locale: locale
        )
        hasEstimatedCycle = summary.map { $0.estimatedMinutes > 0 } ?? false
        detail = OverviewDetailSource(
            snapshot: snapshot, now: now, calendar: calendar, categories: failureCategories, insights: failureInsights, pro: pro
        )

        if isReading {
            phase = .reading
            mosaic = .placeholder(now: now, calendar: calendar, withCycle: summary != nil)
            title = OverviewHeadline.Title(
                situation: .reading, parts: OverviewHeadlineWords.parts(of: OverviewHeadlineWords(locale: locale, calendar: calendar).reading()),
                tone: .neutral, lead: OverviewHeadlineWords(locale: locale, calendar: calendar).readingLine(days: OverviewMosaic.defaultDays), actions: []
            )
            notes = []
            return
        }

        let mosaic = OverviewMosaic(snapshot: snapshot, sidebar: sidebar, summary: summary, now: now, calendar: calendar)
        self.mosaic = mosaic
        if mosaic.isEmpty {
            phase = .empty
            title = OverviewHeadline.Title(
                situation: .reading, parts: OverviewHeadlineWords.parts(of: words.emptyTitle(days: mosaic.days.count)), tone: .neutral,
                lead: words.emptyLine(), actions: []
            )
            notes = []
            return
        }

        var facts = OverviewHeadline.Facts(snapshot: snapshot, mosaic: mosaic, summary: summary, now: now)
        facts.ledger = ledger
        facts.calendar = calendar
        facts.locale = locale
        facts.pro = pro
        facts.failureInsights = failureInsights
        facts.appleStatus = appleStatus
        facts.testFlight = testFlight
        facts.flakyTests = flakyTests
        let headline = OverviewHeadline(facts)
        phase = .ready
        title = headline.title
        notes = headline.notes
    }
}

nonisolated extension OverviewMosaic {
    /// The mosaic of the skeleton: a few apps and workflows of a typical length with a plausible spread of days, none of it
    /// shown as text or as a colour.
    static func placeholder(now: Date, calendar: Calendar = .current, days dayCount: Int = OverviewMosaic.defaultDays, withCycle: Bool = true) -> OverviewMosaic {
        OverviewMosaic(placeholderNow: now, calendar: calendar, days: dayCount, withCycle: withCycle)
    }

    private init(placeholderNow now: Date, calendar: Calendar, days dayCount: Int, withCycle: Bool) {
        self.now = now
        let today = calendar.startOfDay(for: now)
        let count = max(dayCount, 1)
        let days = (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
        self.days = days
        let layout: [(app: String, workflows: [String])] = [("Cumulus", ["Release", "Main", "Pull requests"]), ("Workbench", ["Nightly", "Main"]), ("Atlas", ["Release", "Main"])]
        var seed = 7
        groups = layout.enumerated().map { appIndex, entry in
            let rows = entry.workflows.enumerated().map { rowIndex, name -> Row in
                let cells = days.map { day -> Cell in
                    seed = (seed &* 31 &+ 17) % 97
                    let builds = seed % 5 == 0 ? 0 : 1 + seed % 3
                    return Cell(day: day, builds: builds, succeeded: builds, failed: 0, running: 0, queued: 0)
                }
                return Row(
                    workflowID: "placeholder-\(appIndex)-\(rowIndex)", name: name, productID: "placeholder-\(appIndex)", productKey: entry.app, isPaused: false, cells: cells,
                    successRate: 0.95, medianSeconds: 600, trend: .stable, cycle: withCycle ? CycleMinutes(minutes: 120, isEstimated: false) : nil, failureSeries: nil
                )
            }
            return Group(productID: "placeholder-\(appIndex)", name: entry.app, productKey: entry.app, swatch: .gray, rows: rows)
        }
        hiddenWorkflowCount = 0
    }
}
