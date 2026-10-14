import Foundation

/// The build from which a workflow got slower, found in the durations of its successful builds alone: two levels,
/// one before and one after, with a build between them. Nothing for noise, a slow drift, too few builds, or a workflow
/// that got faster. Pure, so the window and the banners ask the same question.
nonisolated struct WorkflowSlowdown: Equatable, Sendable {
    /// How many successful builds are looked at, newest first.
    static let sampleLimit = 30
    /// Builds needed on each side of the break.
    static let minimumPerSide = 5
    /// The median after must exceed the median before by this fraction...
    static let minimumIncrease = 0.15
    /// ...and by this many seconds.
    static let minimumSeconds: TimeInterval = 60
    /// An action that changed by less than this is not named as a cause.
    static let minimumActionChange: TimeInterval = 15

    /// One successful build, with the time of each of its actions by name.
    struct Sample: Equatable, Sendable {
        let id: String
        let seconds: TimeInterval
        let actions: [String: TimeInterval]
    }

    /// What one action did across the break.
    struct ActionChange: Equatable, Sendable, Identifiable {
        let name: String
        let before: TimeInterval
        let after: TimeInterval

        var id: String { name }
        var delta: TimeInterval { after - before }
    }

    /// The first build of the new level.
    let buildID: String
    /// The builds looked at, oldest first, and where the new level starts among them.
    let sampleIDs: [String]
    let breakIndex: Int
    let medianBefore: TimeInterval
    let medianAfter: TimeInterval
    let buildsBefore: Int
    let buildsAfter: Int
    /// Actions present on both sides, the one that explains the most first.
    let actions: [ActionChange]

    var increase: Double { (medianAfter - medianBefore) / medianBefore }
    var extraSeconds: TimeInterval { medianAfter - medianBefore }
    var idsBefore: ArraySlice<String> { sampleIDs[..<breakIndex] }
    var idsAfter: ArraySlice<String> { sampleIDs[breakIndex...] }

    /// The action behind most of the slowdown, when one clearly is.
    var mainAction: ActionChange? {
        actions.first { $0.delta >= Self.minimumActionChange }
    }

    /// `samples` oldest first; only the newest `sampleLimit` are looked at.
    init?(samples all: [Sample]) {
        let samples = Array(all.suffix(Self.sampleLimit))
        let side = Self.minimumPerSide
        guard samples.count >= 2 * side else { return nil }
        let seconds = samples.map(\.seconds)

        var best: (index: Int, spread: Double)?
        for index in side...(samples.count - side) {
            let before = Array(seconds[..<index])
            let after = Array(seconds[index...])
            guard let medianBefore = WorkflowTrends.median(before), let medianAfter = WorkflowTrends.median(after),
                  Self.isSlower(medianAfter, than: medianBefore),
                  let nearBefore = WorkflowTrends.median(Array(seconds[(index - side)..<index])),
                  let nearAfter = WorkflowTrends.median(Array(seconds[index..<(index + side)])),
                  Self.isSlower(nearAfter, than: nearBefore)
            else { continue }
            // The build that starts the level must already be on it, and the one before it still on the old one.
            let middle = (medianBefore + medianAfter) / 2
            guard seconds[index] > middle, seconds[index - 1] < middle else { continue }
            let spread = before.reduce(0) { $0 + abs($1 - medianBefore) } + after.reduce(0) { $0 + abs($1 - medianAfter) }
            if spread < (best?.spread ?? .infinity) {
                best = (index, spread)
            }
        }
        guard let best,
              let medianBefore = WorkflowTrends.median(Array(seconds[..<best.index])),
              let medianAfter = WorkflowTrends.median(Array(seconds[best.index...]))
        else { return nil }

        let before = samples[..<best.index]
        let after = samples[best.index...]
        buildID = samples[best.index].id
        sampleIDs = samples.map(\.id)
        breakIndex = best.index
        self.medianBefore = medianBefore
        self.medianAfter = medianAfter
        buildsBefore = before.count
        buildsAfter = after.count
        actions = Self.changes(before: before, after: after)
    }

    /// The successful builds of one workflow among `runs`, oldest first, ready for `init(samples:)`.
    static func samples(runs: [CIBuildRun], actionsByRunID: [String: [CIBuildAction]]) -> [Sample] {
        let samples = runs
            .filter { $0.executionProgress == .complete && $0.completionStatus == .succeeded }
            .sorted { ($0.createdDate ?? .distantPast, $0.number ?? 0) < ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            .compactMap { run -> Sample? in
                guard let started = run.startedDate, let finished = run.finishedDate, finished >= started else { return nil }
                var byName: [String: TimeInterval] = [:]
                for action in actionsByRunID[run.id] ?? [] {
                    guard let name = action.name, action.executionProgress == .complete,
                          let start = action.startedDate, let end = action.finishedDate, end >= start
                    else { continue }
                    byName[name, default: 0] += end.timeIntervalSince(start)
                }
                return Sample(id: run.id, seconds: finished.timeIntervalSince(started), actions: byName)
            }
        return Array(samples.suffix(sampleLimit))
    }

    init?(runs: [CIBuildRun], actionsByRunID: [String: [CIBuildAction]]) {
        self.init(samples: Self.samples(runs: runs, actionsByRunID: actionsByRunID))
    }

    /// `https://github.com/<owner>/<repo>/commit/<sha>` and nothing else: any other address is not known for sure.
    static func gitHubCommitURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[2] == "commit", !parts[3].isEmpty, parts[3].allSatisfy(\.isHexDigit) else { return nil }
        return url
    }

    // MARK: - Private

    private static func isSlower(_ after: TimeInterval, than before: TimeInterval) -> Bool {
        before > 0 && after - before >= minimumSeconds && (after - before) / before >= minimumIncrease
    }

    private static func changes(before: ArraySlice<Sample>, after: ArraySlice<Sample>) -> [ActionChange] {
        let names = Set(before.flatMap { $0.actions.keys }).intersection(after.flatMap { $0.actions.keys })
        return names.compactMap { name -> ActionChange? in
            let earlier = before.compactMap { $0.actions[name] }
            let later = after.compactMap { $0.actions[name] }
            guard let medianBefore = WorkflowTrends.median(earlier), let medianAfter = WorkflowTrends.median(later) else { return nil }
            return ActionChange(name: name, before: medianBefore, after: medianAfter)
        }
        .sorted { ($0.delta, $1.name) > ($1.delta, $0.name) }
    }
}
