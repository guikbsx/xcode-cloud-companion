import Foundation

/// How one test went in each of the last builds of its workflow whose test results the app already holds, oldest first.
/// Always a sample: it says how many builds it read.
nonisolated struct TestHistory: Equatable, Sendable {
    static let maxBuilds = 30

    /// A test is the same test when its action, its class and its name are the same, as in `TestHealthReport`.
    struct Identity: Hashable, Sendable {
        let actionName: String
        let className: String?
        let name: String

        init(actionName: String, className: String?, name: String) {
            self.actionName = actionName
            self.className = className?.nilIfBlank
            self.name = name
        }

        init(_ result: CITestResult, actionName: String) {
            self.init(actionName: actionName, className: result.className, name: result.name ?? result.id)
        }

        var key: String { [actionName, className ?? "", name].joined(separator: "\u{1F}") }

        var title: String { [className, name].compactMap(\.self).joined(separator: " · ") }

        /// The identity of every test result of a build, by result id.
        static func identities(of results: [String: [CITestResult]], actions: [CIBuildAction]) -> [String: Identity] {
            var identities: [String: Identity] = [:]
            for action in actions {
                for result in results[action.id] ?? [] {
                    identities[result.id] = Identity(result, actionName: action.name ?? "")
                }
            }
            return identities
        }
    }

    /// What a build says of the test. A skipped test, an expected failure or an unknown state gives no verdict: it counts as absent.
    enum Outcome: Equatable, Sendable {
        case passed, failed, mixed, absent

        init(_ status: CITestStatus?) {
            switch status {
            case .success?: self = .passed
            case .failure?: self = .failed
            case .mixed?: self = .mixed
            default: self = .absent
            }
        }

        var isFailure: Bool { self == .failed || self == .mixed }
    }

    struct DeviceRun: Equatable, Sendable {
        let name: String
        let seconds: Double?
    }

    struct DeviceAverage: Equatable, Sendable {
        let name: String
        let seconds: Double
    }

    /// One analyzed build.
    struct Entry: Identifiable, Equatable, Sendable {
        let runID: String
        let number: Int?
        let date: Date?
        let commit: String?
        var outcome = Outcome.absent
        var message: String?
        var file: CIFileLocation?
        var devices: [DeviceRun] = []

        var id: String { runID }
        var shortCommit: String? { commit.map { String($0.prefix(7)) } }
    }

    /// The failures that run up to the latest build where the test ran, starting at `first`.
    struct Streak: Equatable, Sendable {
        let first: Entry
        let builds: Int
    }

    let identity: Identity
    /// Oldest first, thirty at most.
    let entries: [Entry]
    /// Finished builds of the workflow that ran tests: what a full analysis would cover.
    let eligibleBuilds: Int

    init(identity: Identity, entries: [Entry], eligibleBuilds: Int) {
        self.identity = identity
        self.entries = Array(
            entries
                .sorted { ($0.number ?? 0, $0.date ?? .distantPast) < ($1.number ?? 0, $1.date ?? .distantPast) }
                .suffix(Self.maxBuilds)
        )
        self.eligibleBuilds = max(eligibleBuilds, entries.count)
    }

    /// The popover's skeleton: a history of a typical shape, never shown as figures.
    static let placeholder = TestHistory(
        identity: Identity(actionName: "Test", className: "SettingsTests", name: "testSavingASettingKeepsItsValue()"),
        entries: (1...30).map { (number: Int) -> Entry in
            let outcome: Outcome = [18, 19, 21].contains(number) ? .failed : .passed
            return Entry(runID: "placeholder-\(number)", number: number, date: nil, commit: "a41c7e2", outcome: outcome)
        },
        eligibleBuilds: 41
    )

    var analyzedBuilds: Int { entries.count }
    var failedCount: Int { entries.filter { $0.outcome == .failed }.count }
    var mixedCount: Int { entries.filter { $0.outcome == .mixed }.count }

    /// It differed between devices in a build, or failed and passed on one and the same commit.
    var isFlaky: Bool {
        if mixedCount > 0 { return true }
        let byCommit = Dictionary(grouping: entries.filter { $0.commit != nil && $0.outcome != .absent }, by: { $0.commit ?? "" })
        return byCommit.values.contains { group in
            group.contains { $0.outcome == .failed } && group.contains { $0.outcome == .passed }
        }
    }

    /// Where the failing streak that touches the latest build where the test ran begins; nil when that latest result is a
    /// pass. A build where the test did not run neither extends the streak nor ends it.
    var currentStreak: Streak? {
        let ran = entries.filter { $0.outcome != .absent }
        guard let last = ran.last, last.outcome.isFailure else { return nil }
        var start = ran.count - 1
        while start > 0, ran[start - 1].outcome.isFailure {
            start -= 1
        }
        return Streak(first: ran[start], builds: ran.count - start)
    }

    var lastFailure: Entry? { entries.last { $0.outcome.isFailure } }

    /// The message of the most recent failure that came with one.
    var lastFailureMessage: String? { entries.last { $0.outcome.isFailure && $0.message != nil }?.message }

    /// Mean time on each device, over the builds where the test ran.
    var averageSecondsPerDevice: [DeviceAverage] {
        var seconds: [String: [Double]] = [:]
        for entry in entries where entry.outcome != .absent {
            for device in entry.devices {
                if let duration = device.seconds { seconds[device.name, default: []].append(duration) }
            }
        }
        return seconds
            .map { DeviceAverage(name: $0.key, seconds: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What one build's cached details say of the test, or nil while its tests are not all there.
    static func entry(of run: CIBuildRun, actions: [CIBuildAction], extras: BuildExtras?, identity: Identity) -> Entry? {
        guard let extras, extras.testsComplete else { return nil }
        var found: [CITestResult] = []
        for action in actions where (action.name ?? "") == identity.actionName {
            found += (extras.testsByAction[action.id] ?? []).filter { Identity($0, actionName: identity.actionName) == identity }
        }
        let entry = Entry(runID: run.id, number: run.number, date: run.createdDate, commit: run.sourceCommit?.commitSha?.nilIfBlank)
        guard let result = found.first(where: { $0.status.isFailure }) ?? found.first(where: { $0.status == .success }) else { return entry }
        var seen = entry
        seen.outcome = Outcome(result.status)
        guard seen.outcome != .absent else { return seen }
        if seen.outcome.isFailure {
            seen.message = result.message?.nilIfBlank
            seen.file = result.file
        }
        seen.devices = result.devices.map { DeviceRun(name: $0.deviceName, seconds: $0.duration) }
        return seen
    }
}
