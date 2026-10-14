import Foundation
import Observation

/// What the app knows of Apple's incidents on Xcode Cloud. One for the app: the page does not depend on the account.
/// It is read when a build ends in error or when the sheet of such a build opens, at most once in ten minutes, and while the
/// user waits for an incident to end. Nothing else reads it, and nothing is kept on disk.
@Observable
final class AppleStatusStore {
    struct Watch: Equatable {
        let incidentStart: Date
        let since: Date
    }

    private(set) var knowledge: AppleStatusKnowledge?
    /// Asked for by the user and kept in memory only: it ends when the app quits.
    private(set) var watch: Watch?

    @ObservationIgnored private let fetcher: (any AppleStatusFetching)?
    @ObservationIgnored private let notify: @MainActor ([LocalNotification]) async -> Void
    @ObservationIgnored private let requestAuthorization: @MainActor () async -> Void
    @ObservationIgnored private let erroredBuilds: @MainActor (DateInterval) -> Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var accountsWithBaseline: Set<String> = []
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    /// A nil `fetcher` reads nothing, ever: tests, and a Debug build with a pinned state.
    init(
        fetcher: (any AppleStatusFetching)?,
        notify: @escaping @MainActor ([LocalNotification]) async -> Void = { _ in },
        requestAuthorization: @escaping @MainActor () async -> Void = {},
        erroredBuilds: @escaping @MainActor (DateInterval) -> Int = { _ in 0 },
        pinned events: [AppleStatusEvent]? = nil,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.fetcher = fetcher
        self.notify = notify
        self.requestAuthorization = requestAuthorization
        self.erroredBuilds = erroredBuilds
        self.now = now
        self.sleep = sleep
        // A pinned state never grows old.
        knowledge = events.map { AppleStatusKnowledge(events: $0, readAt: .distantFuture) }
    }

    /// `XCC_APPLE_STATUS=incident|resolved` in a Debug build: an incident that began a day ago, still going on or closed an hour ago.
    static func pinnedEvents(named name: String?, now: Date) -> [AppleStatusEvent]? {
        let start = now.addingTimeInterval(-24 * 3600)
        return switch name {
        case "incident": [AppleStatusEvent(start: start, end: nil)]
        case "resolved": [AppleStatusEvent(start: start, end: now.addingTimeInterval(-3600))]
        default: nil
        }
    }

    // MARK: - What is known

    func ongoingIncident(at date: Date) -> AppleStatusEvent? {
        knowledge?.ongoing(at: date)
    }

    /// The event that covers when a build stopped; only builds that ended in error have one.
    func event(covering run: CIBuildRun, at date: Date) -> AppleStatusEvent? {
        guard AppleStatusSchedule.isErrored(run) else { return nil }
        return knowledge?.event(covering: run, now: date)
    }

    var isWatching: Bool { watch != nil }

    // MARK: - Reading

    /// One account's sync. The first sync of an account in a session only says where things stand.
    func buildsDidSync(accountID: String, previous: BuildSnapshot, current: BuildSnapshot) async {
        guard accountsWithBaseline.contains(accountID) else {
            accountsWithBaseline.insert(accountID)
            return
        }
        guard !AppleStatusSchedule.erroredFinishes(previous: previous, current: current, now: now()).isEmpty else { return }
        await readIfAllowed()
    }

    /// The sheet of a build is on screen.
    func sheetDidOpen(for run: CIBuildRun) async {
        guard AppleStatusSchedule.sheetOpensRead(run: run, now: now()) else { return }
        await readIfAllowed()
    }

    // MARK: - Watching

    /// Reads the page every five minutes, for twelve hours at most, and says when the incident is over.
    func startWatching(_ event: AppleStatusEvent) {
        guard watch == nil, event.isOngoing else { return }
        watch = Watch(incidentStart: event.start, since: now())
        // Asked now, while the user is looking at the button: a banner hours later is a poor moment for a permission sheet.
        Task { await requestAuthorization() }
        watchTask = Task { await watchLoop() }
    }

    /// Ends when the watch does.
    func settleWatch() async {
        await watchTask?.value
    }

    // MARK: - Private

    private func readIfAllowed() async {
        guard fetcher != nil, !isReading, AppleStatusSchedule.mayRead(lastAttempt: lastAttempt, now: now()) else { return }
        _ = await read()
    }

    private func read() async -> AppleStatusReading? {
        guard let fetcher, !isReading else { return nil }
        isReading = true
        defer { isReading = false }
        lastAttempt = now()
        let reading = (try? await fetcher.fetch()).map(AppleStatusDecoder.decode) ?? .unknown
        if case .events(let events) = reading {
            knowledge = AppleStatusKnowledge(events: events, readAt: now())
        }
        return reading
    }

    private func watchLoop() async {
        while let watch, !Task.isCancelled {
            await sleep(.seconds(AppleStatusSchedule.watchInterval))
            guard !Task.isCancelled else { return }
            let reading = await read()
            switch AppleStatusSchedule.watchOutcome(reading: reading, incidentStart: watch.incidentStart, watchingSince: watch.since, now: now()) {
            case .keepWatching:
                continue
            case .expired:
                self.watch = nil
            case .resolved(let interval):
                self.watch = nil
                await notify([AppleStatusFormat.recoveryNotification(erroredBuilds: erroredBuilds(interval))])
            }
        }
    }
}
