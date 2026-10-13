import Foundation

/// What the widgets draw. The app writes it into the shared container after each sync; the widget extension reads it
/// and nothing else: it has no key, no network, and none of the app's preferences (colours included).
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let fileName = "Widgets.json"
    static let currentSchema = 1

    struct Tint: Codable, Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    enum BuildState: String, Codable, Sendable {
        case running, succeeded, failed, errored, canceled, skipped, finished
    }

    struct App: Codable, Equatable, Sendable, Identifiable {
        /// The product's id, which is what a configured widget remembers.
        var id: String
        var name: String
        var tint: Tint
    }

    struct Build: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var appID: String
        var app: String
        var number: Int?
        var workflow: String?
        var state: BuildState
        var failedTests: Int?
        /// When it ended; while it runs, when it started.
        var date: Date?
        var durationSeconds: Int?
        var tint: Tint

        /// “Pollen #394”, or the app alone while Apple has not numbered the build.
        var title: String {
            number.map { "\(app) #\($0)" } ?? app
        }

        var url: URL? {
            URL(string: "cumulus://build/\(id)")
        }
    }

    struct Segment: Codable, Equatable, Sendable {
        var app: String
        var minutes: Double
        var tint: Tint
    }

    struct Cycle: Codable, Equatable, Sendable {
        var usedMinutes: Double
        var quotaMinutes: Double
        /// The whole percentage the app writes everywhere else, so that a widget never says another figure.
        var percentUsed: Int
        var isEstimate: Bool
        /// While builds are still measured the app shows no figure, and neither does a widget.
        var isMeasuring: Bool
        var resetDate: Date
        /// One per app, biggest consumer first.
        var segments: [Segment]

        /// The ring or bar, as shares of the plan: each app's arc from where the one before ends, never past the plan.
        var arcs: [(start: Double, end: Double, tint: Tint)] {
            guard quotaMinutes > 0 else { return [] }
            var cursor = 0.0
            var arcs: [(start: Double, end: Double, tint: Tint)] = []
            for segment in segments where segment.minutes > 0 && cursor < 1 {
                let end = min(1, cursor + segment.minutes / quotaMinutes)
                arcs.append((cursor, end, segment.tint))
                cursor = end
            }
            return arcs
        }
    }

    var schema = WidgetSnapshot.currentSchema
    var generatedAt: Date
    /// False while the app follows no account: there is nothing to show but the way in.
    var hasAccount: Bool
    var apps: [App] = []
    /// Newest first: the newest of every app, and the newest overall.
    var builds: [Build] = []
    /// Nil without a reset date: there is no cycle to draw.
    var cycle: Cycle?

    static func empty(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: date, hasAccount: false)
    }

    /// The newest build of one app, or of all of them.
    func latestBuild(appID: String?) -> Build? {
        builds.first { appID == nil || $0.appID == appID }
    }

    func recentBuilds(limit: Int) -> [Build] {
        Array(builds.prefix(limit))
    }

    /// Whether anything but the date it was written differs: the widgets are told to redraw only then.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        var copy = other
        copy.generatedAt = generatedAt
        return copy == self
    }
}

nonisolated extension WidgetSnapshot {
    /// What a build widget has to say.
    enum BuildFace: Equatable, Sendable {
        case noAccount
        case noBuild
        case build(Build)
    }

    /// What a cycle widget has to say.
    enum CycleFace: Equatable, Sendable {
        case noAccount
        case noPlan
        case measuring
        case cycle(Cycle)
    }

    func buildFace(appID: String?) -> BuildFace {
        guard hasAccount else { return .noAccount }
        return latestBuild(appID: appID).map(BuildFace.build) ?? .noBuild
    }

    var cycleFace: CycleFace {
        guard hasAccount else { return .noAccount }
        guard let cycle else { return .noPlan }
        return cycle.isMeasuring ? .measuring : .cycle(cycle)
    }
}

/// In the shared container, beside the registry of accounts.
nonisolated struct WidgetSnapshotStore: Sendable {
    var fileURL: URL

    init(directory: URL) {
        fileURL = directory.appending(path: WidgetSnapshot.fileName)
    }

    /// Nil when nothing was written yet, or by a version whose file this one does not read.
    func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.schema == WidgetSnapshot.currentSchema
        else { return nil }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: WidgetSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
