import Foundation

/// What the ring of a build draws: one arc per action, in the order of the actions frieze, as fractions of a turn from the
/// top, clockwise. Worked out from the snapshot alone; a running build is laid out against the usual duration of each action.
nonisolated struct BuildRing: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// A build that is over, with its actions.
        case finished
        /// Running, within the usual durations.
        case running
        /// Running, and the current action has outlasted its usual duration: `overflow` is the second lap.
        case overrun
        /// Running, with an action that has fewer than three successful runs to compare to, or no workflow: no track to the end.
        case unestimated
        /// Not started yet: no arc.
        case queued
        /// A build Apple skipped.
        case skipped
        /// Its actions are not known (not read yet, or an older build): only the state of the build can be drawn.
        case unknown
    }

    /// What marks an arc so that the state does not rest on colour alone.
    enum Marker: Equatable, Sendable {
        case none
        /// A failure.
        case cross
        /// An error on Apple's side.
        case slit
        /// What did not run: skipped, never started after a stop. An action canceled while it ran keeps its short grey arc, as on 6.3.
        case dashed
    }

    struct Arc: Equatable, Sendable {
        let start: Double
        let length: Double
        let status: BuildStatus
        let marker: Marker
        /// How much of the arc is drawn full, from its start: all of a finished action, the elapsed part of the running one,
        /// nothing of what has not begun or did not run. The rest is pale (`isEstimated`) or empty.
        let solidLength: Double
        /// Part of the arc is the usual duration of an action that has not finished.
        let isEstimated: Bool
        /// How many actions the arc stands for; more than one when short arcs were merged.
        let mergedCount: Int

        var end: Double { start + length }
    }

    /// The visible space between two arcs, in turns: the mockups leave 3° at 56 pt and 8° at 26 pt. A view that rounds the ends of
    /// its arcs takes the caps out of the arcs, not out of this space.
    static let gap = 6.0 / 360
    /// An arc shorter than this merges with its neighbour.
    static let minimumArc = 4.0 / 360
    /// Without an estimate, the elapsed time that fills a turn.
    static let unestimatedTurn: TimeInterval = 600
    /// The move of the head that is worth a redraw, in turns.
    static let visibleStep = 1.0 / 120
    static let shortestRedraw: TimeInterval = 10
    static let longestRedraw: TimeInterval = 60

    let state: State
    /// The state of the build, for the colour of a ring whose arcs are not known.
    let status: BuildStatus
    let arcs: [Arc]
    /// The present moment of a running build, in turns; nil for any other.
    let head: Double?
    /// Past a full turn, how far the current action has gone over its usual duration, in turns (never above 1).
    let overflow: Double?
    /// The ring in words, for VoiceOver.
    let spokenDescription: String
    /// The next time the ring looks different, for a view that redraws at that moment only; nil when nothing moves.
    let nextChange: Date?

    init(run: CIBuildRun, in snapshot: BuildSnapshot, now: Date, locale: Locale = .autoupdatingCurrent) {
        self = Self.make(run: run, snapshot: snapshot, now: now, locale: locale)
    }

    private init(state: State, status: BuildStatus, arcs: [Arc] = [], head: Double? = nil, overflow: Double? = nil, spoken: String, nextChange: Date? = nil) {
        self.state = state
        self.status = status
        self.arcs = arcs
        self.head = head
        self.overflow = overflow
        spokenDescription = spoken
        self.nextChange = nextChange
    }
}

// MARK: - Building

nonisolated extension BuildRing {
    /// Actions of the same name are one: a rerun is added to the first attempt, as its time is.
    private struct Group {
        enum Phase { case done, notRun, active, waiting }

        let name: String
        let last: CIBuildAction
        let phase: Phase
        let status: BuildStatus
        let marker: Marker
        /// Time of the attempts that finished.
        let completed: TimeInterval
        /// Time the running attempt has been going.
        let elapsed: TimeInterval
    }

    private struct Segment {
        var weight: Double
        var solid: Double
        var past: Double
        var status: BuildStatus
        var marker: Marker
        var count = 1
        var isEstimated = false
    }

    private static func make(run: CIBuildRun, snapshot: BuildSnapshot, now: Date, locale: Locale) -> BuildRing {
        let status = BuildStatus(run: run)
        if run.executionProgress == .pending {
            return BuildRing(state: .queued, status: status, spoken: String(localized: LocalizedStringResource("Waiting to start", locale: locale, comment: "A build that Apple has not started yet")))
        }
        if run.executionProgress != .running, run.completionStatus == .skipped {
            return BuildRing(state: .skipped, status: status, spoken: label(.skipped, locale: locale))
        }
        let actions = snapshot.actionsByRunID[run.id] ?? []
        guard !actions.isEmpty else {
            return BuildRing(state: .unknown, status: status, spoken: label(status, locale: locale))
        }
        let running = run.executionProgress == .running
        let groups = groups(of: actions, buildRunning: running, now: now)
        return running
            ? makeRunning(run: run, status: status, groups: groups, snapshot: snapshot, now: now, locale: locale)
            : makeFinished(run: run, status: status, groups: groups, snapshot: snapshot, locale: locale)
    }

    private static func makeFinished(run: CIBuildRun, status: BuildStatus, groups: [Group], snapshot: BuildSnapshot, locale: Locale) -> BuildRing {
        let fallback = meanDuration(of: groups)
        var segments = groups.map { group -> Segment in
            switch group.phase {
            case .done:
                Segment(weight: group.completed, solid: group.completed, past: group.completed, status: group.status, marker: group.marker)
            default:
                Segment(
                    weight: BuildNotificationPlanner.usualSeconds(of: group.last, run: run, in: snapshot) ?? fallback ?? 1,
                    solid: 0, past: 0, status: group.status, marker: group.marker
                )
            }
        }
        if segments.reduce(0, { $0 + $1.weight }) <= 0 {
            segments = segments.map { Segment(weight: 1, solid: $0.solid > 0 ? 1 : 0, past: 0, status: $0.status, marker: $0.marker) }
        }
        let scale = segments.reduce(0) { $0 + $1.weight }
        let laidOut = layout(segments, scale: scale)
        return BuildRing(state: .finished, status: status, arcs: laidOut.arcs, spoken: spokenFinished(groups, locale: locale))
    }

    private static func makeRunning(run: CIBuildRun, status: BuildStatus, groups: [Group], snapshot: BuildSnapshot, now: Date, locale: Locale) -> BuildRing {
        let usuals = groups.map { group -> TimeInterval? in
            group.phase == .done ? nil : BuildNotificationPlanner.usualSeconds(of: group.last, run: run, in: snapshot)
        }
        let unfinished = groups.indices.filter { groups[$0].phase == .active || groups[$0].phase == .waiting }
        let estimated = run.workflowID != nil && unfinished.allSatisfy { usuals[$0] != nil }

        let eta = BuildETA(run: run, among: snapshot.runs, now: now)
        let activeNames = groups.filter { $0.phase == .active }

        if estimated {
            let fallback = meanDuration(of: groups)
            var overrun: TimeInterval = 0
            var usualEnd: Date?
            var segments: [Segment] = []
            for (index, group) in groups.enumerated() {
                let usual = usuals[index]
                switch group.phase {
                case .done:
                    segments.append(Segment(weight: group.completed, solid: group.completed, past: group.completed, status: group.status, marker: group.marker))
                case .notRun:
                    let weight = usual ?? fallback ?? 1
                    segments.append(Segment(weight: weight, solid: 0, past: weight, status: group.status, marker: group.marker))
                case .active:
                    let usual = usual ?? 0
                    let reached = group.completed + min(group.elapsed, usual)
                    overrun = max(overrun, group.elapsed - usual)
                    if group.elapsed < usual, let start = group.last.startedDate { usualEnd = start.addingTimeInterval(usual) }
                    segments.append(Segment(
                        weight: group.completed + usual, solid: reached, past: reached, status: group.status, marker: group.marker,
                        isEstimated: group.elapsed < usual
                    ))
                case .waiting:
                    segments.append(Segment(weight: usual ?? 0, solid: 0, past: 0, status: group.status, marker: group.marker, isEstimated: true))
                }
            }
            let scale = segments.reduce(0) { $0 + $1.weight }
            if scale > 0 {
                let laidOut = layout(segments, scale: scale)
                var next = now.addingTimeInterval(min(Self.longestRedraw, max(Self.shortestRedraw, scale * Self.visibleStep)))
                if let usualEnd, usualEnd > now { next = min(next, usualEnd.addingTimeInterval(0.1)) }
                return BuildRing(
                    state: overrun > 0 ? .overrun : .running, status: status, arcs: laidOut.arcs, head: laidOut.head,
                    overflow: overrun > 0 ? min(1, overrun / scale) : nil,
                    spoken: spokenRunning(activeNames, overrun: overrun > 0, eta: eta, now: now, locale: locale), nextChange: next
                )
            }
        }

        let segments = groups.compactMap { group -> Segment? in
            switch group.phase {
            case .done:
                Segment(weight: group.completed, solid: group.completed, past: group.completed, status: group.status, marker: group.marker)
            case .active:
                Segment(weight: group.completed + group.elapsed, solid: group.completed + group.elapsed, past: group.completed + group.elapsed, status: group.status, marker: group.marker)
            case .notRun, .waiting:
                nil
            }
        }
        let scale = max(Self.unestimatedTurn, segments.reduce(0) { $0 + $1.weight })
        let laidOut = layout(segments, scale: scale)
        return BuildRing(
            state: .unestimated, status: status, arcs: laidOut.arcs, head: laidOut.head ?? 0,
            spoken: spokenRunning(activeNames, overrun: false, eta: nil, now: now, locale: locale),
            nextChange: now.addingTimeInterval(min(Self.longestRedraw, max(Self.shortestRedraw, Self.unestimatedTurn * Self.visibleStep)))
        )
    }

    // MARK: Groups

    private static func groups(of actions: [CIBuildAction], buildRunning: Bool, now: Date) -> [Group] {
        var order: [String] = []
        var byName: [String: [CIBuildAction]] = [:]
        for action in BuildDetailModel.ordered(actions) {
            let key = action.name ?? action.id
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(action)
        }
        return order.compactMap { key in
            guard let attempts = byName[key], let last = attempts.last else { return nil }
            let hasStart = last.startedDate != nil
            let phase: Group.Phase = switch last.executionProgress {
            case .running: hasStart ? .active : (buildRunning ? .waiting : .notRun)
            case .pending: buildRunning ? .waiting : .notRun
            default: last.completionStatus == .skipped || !hasStart ? .notRun : .done
            }
            let status: BuildStatus
            let marker: Marker
            switch phase {
            case .active, .waiting:
                status = .running
                marker = .none
            case .notRun:
                status = last.completionStatus == .canceled ? .canceled : .skipped
                marker = .dashed
            case .done:
                status = BuildStatus(action: last)
                marker = switch status {
                case .failed: .cross
                case .errored: .slit
                case .skipped: .dashed
                default: .none
                }
            }
            let completed = attempts.reduce(0) { total, attempt in
                guard attempt.executionProgress != .running, attempt.executionProgress != .pending,
                      let started = attempt.startedDate, let finished = attempt.finishedDate
                else { return total }
                return total + max(0, finished.timeIntervalSince(started))
            }
            let elapsed = phase == .active ? max(0, now.timeIntervalSince(last.startedDate ?? now)) : 0
            return Group(
                name: BuildDetailModel.name(of: last), last: last, phase: phase, status: status, marker: marker,
                completed: completed, elapsed: elapsed
            )
        }
    }

    private static func meanDuration(of groups: [Group]) -> TimeInterval? {
        let durations = groups.filter { $0.phase == .done && $0.completed > 0 }.map(\.completed)
        return durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
    }

    // MARK: Layout

    /// The arcs for `segments`, `scale` being the weight of a full turn. The arcs and the gaps make a turn when the weights
    /// add up to the scale; arcs under `minimumArc` merge with their shorter neighbour until none is left.
    private static func layout(_ input: [Segment], scale: Double) -> (arcs: [Arc], head: Double?) {
        guard !input.isEmpty else { return ([], nil) }
        let scale = scale > 0 ? scale : 1
        var segments = input
        while segments.count > 1 {
            let usable = 1 - Double(segments.count) * gap
            guard let smallest = segments.indices.min(by: { segments[$0].weight < segments[$1].weight }),
                  segments[smallest].weight / scale * usable < minimumArc
            else { break }
            let neighbour: Int
            if smallest == 0 {
                neighbour = 1
            } else if smallest == segments.count - 1 {
                neighbour = smallest - 1
            } else {
                neighbour = segments[smallest - 1].weight <= segments[smallest + 1].weight ? smallest - 1 : smallest + 1
            }
            let low = min(smallest, neighbour)
            segments[low] = merged(segments[low], segments[low + 1])
            segments.remove(at: low + 1)
        }

        let usable = max(0, 1 - Double(segments.count) * gap)
        var cursor = 0.0
        var arcs: [Arc] = []
        var pastLengths: [Double] = []
        for segment in segments {
            let length = segment.weight / scale * usable
            let ratio = segment.weight > 0 ? length / segment.weight : 0
            arcs.append(Arc(
                start: cursor, length: length, status: segment.status, marker: segment.marker, solidLength: segment.solid * ratio,
                isEstimated: segment.isEstimated, mergedCount: segment.count
            ))
            pastLengths.append(segment.past * ratio)
            cursor += length + gap
        }

        var head = arcs.last?.end
        for (index, (arc, past)) in zip(arcs, pastLengths).enumerated() where past < arc.length - 1e-9 {
            head = past > 0 || index == 0 ? arc.start + past : arcs[index - 1].end
            break
        }
        return (arcs, head)
    }

    private static func merged(_ lhs: Segment, _ rhs: Segment) -> Segment {
        let worse = severity(rhs.status) > severity(lhs.status) ? rhs : lhs
        return Segment(
            weight: lhs.weight + rhs.weight, solid: lhs.solid + rhs.solid, past: lhs.past + rhs.past, status: worse.status,
            marker: worse.marker, count: lhs.count + rhs.count, isEstimated: lhs.isEstimated || rhs.isEstimated
        )
    }

    private static func severity(_ status: BuildStatus) -> Int {
        switch status {
        case .succeeded, .finished: 0
        case .skipped: 1
        case .canceled: 2
        case .running: 3
        case .errored: 4
        case .failed: 5
        }
    }

    // MARK: Words

    private static func spokenFinished(_ groups: [Group], locale: Locale) -> String {
        groups.map { group -> String in
            let name = group.name
            if group.phase == .notRun {
                return String(localized: LocalizedStringResource("\(name) not run", locale: locale, comment: "Said by VoiceOver for an action of a build that did not run"))
            }
            let time = duration(group.completed, locale: locale)
            return switch group.status {
            case .failed:
                String(localized: LocalizedStringResource("\(name) \(time) failed", locale: locale, comment: "Said by VoiceOver for an action of a build that failed: its name, its time"))
            case .errored:
                String(localized: LocalizedStringResource("\(name) \(time) errored", locale: locale, comment: "Said by VoiceOver for an action of a build that ended in an error on Apple's side: its name, its time"))
            case .canceled:
                String(localized: LocalizedStringResource("\(name) \(time) canceled", locale: locale, comment: "Said by VoiceOver for an action of a build that was canceled: its name, its time"))
            default:
                "\(name) \(time)"
            }
        }.joined(separator: ", ")
    }

    private static func spokenRunning(_ active: [Group], overrun: Bool, eta: BuildETA?, now: Date, locale: Locale) -> String {
        var parts = active.map { group -> String in
            let name = group.name
            let time = duration(group.completed + group.elapsed, locale: locale)
            return String(localized: LocalizedStringResource("\(name) running for \(time)", locale: locale, comment: "Said by VoiceOver for the action of a build that is running: its name, the time it has been running"))
        }
        if parts.isEmpty { parts = [label(.running, locale: locale)] }
        if overrun {
            parts.append(String(localized: LocalizedStringResource("longer than usual", locale: locale, comment: "Said by VoiceOver for a running build whose current action has outlasted its usual duration")))
        } else if let display = eta?.display(at: now) {
            parts.append(BuildETAFormat.spoken(display, locale: locale))
        }
        return parts.joined(separator: ", ")
    }

    /// “2 min 1 sec”: each unit on its own, so that no comma comes between them in a sentence that is made of commas.
    private static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let total = Int(max(0, seconds).rounded())
        let units: [(Duration.UnitsFormatStyle.Unit, Int)] = [(.hours, total / 3600), (.minutes, total % 3600 / 60), (.seconds, total % 60)]
        let shown = units.drop { $0.1 == 0 }.prefix(2).filter { $0.1 > 0 }
        let parts = (shown.isEmpty ? [(Duration.UnitsFormatStyle.Unit.seconds, 0)] : Array(shown)).map { unit, value in
            Duration.seconds(value * (unit == .hours ? 3600 : unit == .minutes ? 60 : 1))
                .formatted(.units(allowed: [unit], width: .abbreviated).locale(locale))
        }
        return parts.joined(separator: " ")
    }

    private static func label(_ status: BuildStatus, locale: Locale) -> String {
        switch status {
        case .running: String(localized: LocalizedStringResource("Running", locale: locale))
        case .succeeded: String(localized: LocalizedStringResource("Succeeded", locale: locale))
        case .failed: String(localized: LocalizedStringResource("Failed", locale: locale))
        case .errored: String(localized: LocalizedStringResource("Error", locale: locale))
        case .canceled: String(localized: LocalizedStringResource("Canceled", locale: locale))
        case .skipped: String(localized: LocalizedStringResource("Skipped", locale: locale))
        case .finished: String(localized: LocalizedStringResource("Finished", locale: locale))
        }
    }
}
