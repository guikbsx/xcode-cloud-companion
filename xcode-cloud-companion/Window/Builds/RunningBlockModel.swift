import Foundation

/// What the block at the head of the build list says of the builds that run: one entry per build, in the order of
/// `RunningBuildsETA` (the bar and the menu's), with the words of its ring and of its line of the legend.
nonisolated struct RunningBlockModel: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let productID: String
        /// The key of the app's colour.
        let paletteKey: String
        let appName: String
        let initial: String
        /// “Sextant #412”.
        let title: String
        let workflow: String?
        let reference: String?
        /// “Archive running”, or “Waiting to start”.
        let action: String
        /// The legend's second line: the action and when it should end, or how long the build has queued.
        let detail: String
        /// The legend's lines under the title: the action by name and when it ends; a queued build has only its wait.
        let legendLines: [String]
        /// “Release · main”: the card's second line; nil without a workflow or a reference.
        let facts: String?
        /// The card's last line, in one: the action and when it ends, or the action and when the build started, or the wait.
        let summary: String
        let isQueued: Bool
        let ring: BuildRing
        let centerText: String
        let centerDetail: String?
        let spoken: String
    }

    let items: [Item]
    /// Running builds the block gives no ring to; they are in the list below.
    let more: Int

    /// The legend names each app by its icon only when the builds of the block are of several apps.
    var mixesApps: Bool { Set(items.map(\.productID)).count > 1 }

    /// How many builds run, those of the block and the others.
    var total: Int { items.count + more }

    /// `ids` are the builds the list gave to the block; their order and their end times are those of `RunningBuildsETA`.
    init(ids: [String], more: Int, snapshot: BuildSnapshot, now: Date, locale: Locale = .autoupdatingCurrent) {
        let wanted = Set(ids)
        self.more = more
        items = RunningBuildsETA.entries(in: snapshot, now: now)
            .filter { wanted.contains($0.run.id) }
            .prefix(BuildRingMetrics.mostConcentric)
            .map { Self.item(for: $0, snapshot: snapshot, now: now, locale: locale) }
    }

    private static func item(for entry: RunningBuildsETA.Entry, snapshot: BuildSnapshot, now: Date, locale: Locale) -> Item {
        let run = entry.run
        let line = RunningBuildLine(entry: entry, snapshot: snapshot, now: now, locale: locale)
        let product = snapshot.product(id: run.productID)
        let name = product?.displayName ?? "?"
        let isQueued = run.executionProgress == .pending
        let display = entry.eta.flatMap { $0.display(at: now) }
        let end = display == nil ? nil : entry.eta?.expectedEnd
        let ends = end.map { Words.endsAround($0, locale: locale) }

        let detail: String
        let legendLines: [String]
        let centerText: String
        var centerDetail: String?
        let summary: String
        if isQueued {
            detail = Words.queued(since: run.createdDate, now: now, locale: locale)
            legendLines = [detail]
            centerText = Words.queuedShort(locale: locale)
            summary = detail
        } else if let display, let ends {
            detail = UsageFormat.dotted([line.actionName ?? line.action, ends], locale: locale)
            legendLines = [line.actionName ?? line.action, ends]
            centerText = BuildETAFormat.approximate(display, locale: locale)
            centerDetail = ends
            summary = detail
        } else {
            detail = line.action
            legendLines = [line.actionName ?? line.action]
            let started = run.startedDate ?? run.createdDate
            centerText = started.map { BuildRowData.clock(max(0, now.timeIntervalSince($0))) } ?? line.action
            centerDetail = started.map { Words.since($0, locale: locale) }
            summary = UsageFormat.dotted([line.action, centerDetail].compactMap(\.self), locale: locale)
        }
        let facts = [line.workflow, line.reference].compactMap(\.self).filter { !$0.isEmpty }
        let spoken = [line.title, line.workflow, line.reference, isQueued ? Words.queued(since: run.createdDate, now: now, locale: locale) : line.action, line.spokenEnd]
            .compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
        return Item(
            id: run.id, productID: run.productID, paletteKey: product?.name ?? name, appName: name, initial: String(name.prefix(1)).uppercased(),
            title: line.title, workflow: line.workflow, reference: line.reference, action: line.action, detail: detail, legendLines: legendLines,
            facts: facts.isEmpty ? nil : UsageFormat.dotted(facts, locale: locale), summary: summary, isQueued: isQueued, ring: BuildRing(run: run, in: snapshot, now: now, locale: locale), centerText: centerText,
            centerDetail: centerDetail, spoken: spoken
        )
    }

    // MARK: Words

    /// The block as one element for VoiceOver: how many builds run.
    func spokenCount(locale: Locale = .autoupdatingCurrent) -> String {
        Words.count(total, locale: locale)
    }

    func moreText(locale: Locale = .autoupdatingCurrent) -> String {
        Words.more(more, locale: locale)
    }

    func centerCount(locale: Locale = .autoupdatingCurrent) -> (text: String, detail: String) {
        (total.formatted(.number.locale(locale)), Words.runningShort(locale: locale))
    }

    enum Words {
        static func endsAround(_ end: Date, locale: Locale) -> String {
            String(localized: LocalizedStringResource("ends ~\(UsageFormat.time(end, locale: locale))", locale: locale, comment: "When a running build should end, in a few words: “ends ~2:49 PM”. It goes under a ring and in a legend."))
        }

        static func since(_ start: Date, locale: Locale) -> String {
            String(localized: LocalizedStringResource("started \(UsageFormat.time(start, locale: locale))", locale: locale, comment: "When a running build with no estimate started: “started 2:36 PM”. Very short. It goes under a ring."))
        }

        static func queued(since created: Date?, now: Date, locale: Locale) -> String {
            guard let created, now.timeIntervalSince(created) >= 60 else {
                return String(localized: LocalizedStringResource("In queue", locale: locale, comment: "A build that waits for Apple to start it, in the legend of the running builds"))
            }
            let minutes = UsageFormat.minutes((now.timeIntervalSince(created) / 60).rounded(.down), locale: locale)
            return String(localized: LocalizedStringResource("In queue for \(minutes)", locale: locale, comment: "A build that waits for Apple to start it; the argument is a duration such as “3 min”"))
        }

        static func queuedShort(locale: Locale) -> String {
            String(localized: LocalizedStringResource("Queued", locale: locale, comment: "In a line of the bubble of a day of the Overview: the build waits in the queue. Very short."))
        }

        static func runningShort(locale: Locale) -> String {
            String(localized: LocalizedStringResource("running", locale: locale, comment: "State of a running build, in lowercase"))
        }

        static func count(_ count: Int, locale: Locale) -> String {
            String(localized: LocalizedStringResource("\(count) builds running", locale: locale, comment: "Said by VoiceOver for the block that heads the build list"))
        }

        static func more(_ count: Int, locale: Locale) -> String {
            String(localized: LocalizedStringResource("and \(count) more running", locale: locale, comment: "Under the rings of the running builds: the others, listed below. “and 2 more running”"))
        }
    }
}

/// Where a tap on the nested rings lands.
nonisolated enum RunningBlockHit {
    /// The ring (0 is the outer one) nearest to `point` in a square of `size` holding `count` rings of `lineWidth`.
    static func ringIndex(at point: CGPoint, size: CGFloat, lineWidth: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let distance = hypot(point.x - size / 2, point.y - size / 2)
        let pitch = lineWidth + BuildRingMetrics.concentricGap
        let index = ((size / 2 - lineWidth / 2 - distance) / pitch).rounded()
        return min(max(Int(index), 0), count - 1)
    }
}
