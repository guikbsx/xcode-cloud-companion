import AppIntents
import SwiftUI
import WidgetKit

/// What a widget draws at one moment: the file the app wrote, and the app a build widget is set on.
struct FeedEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var appID: String?
}

/// The widgets read one file of the shared container. No key, no network: what the app last wrote is all they know.
enum Feed {
    /// The app tells the widgets when its file changed; this is only how long a widget waits when it is not told.
    static let refreshInterval: TimeInterval = 15 * 60

    static func load(now: Date) -> WidgetSnapshot {
        WidgetSnapshotStore(directory: SharedContainer.applicationSupport).load() ?? .empty(at: now)
    }

    static func timeline(appID: String? = nil) -> Timeline<FeedEntry> {
        let now = Date()
        return Timeline(entries: [FeedEntry(date: now, snapshot: load(now: now), appID: appID)], policy: .after(now.addingTimeInterval(refreshInterval)))
    }

    /// For the gallery and placeholders: made-up builds, never the user's own, which a placeholder could show on a locked screen.
    static var sample: WidgetSnapshot {
        let now = Date()
        let coral = WidgetSnapshot.Tint(red: 0.85, green: 0.36, blue: 0.29)
        let indigo = WidgetSnapshot.Tint(red: 0.33, green: 0.26, blue: 0.93)
        let violet = WidgetSnapshot.Tint(red: 0.50, green: 0.35, blue: 0.82)
        return WidgetSnapshot(
            generatedAt: now,
            hasAccount: true,
            apps: [],
            builds: [
                .init(id: "sample-1", appID: "a", app: "Pollen", number: 394, workflow: "Release", state: .succeeded, date: now.addingTimeInterval(-300), durationSeconds: 840, tint: indigo),
                .init(id: "sample-2", appID: "b", app: "Brioche", number: 212, workflow: "CI", state: .failed, failedTests: 3, date: now.addingTimeInterval(-3600), durationSeconds: 360, tint: coral),
                .init(id: "sample-3", appID: "c", app: "Sextant", number: 88, workflow: "Nightly", state: .running, date: now.addingTimeInterval(-720), tint: violet),
            ],
            cycle: .init(
                usedMinutes: 817, quotaMinutes: 1500, percentUsed: 54, isEstimate: true, isMeasuring: false, resetDate: now.addingTimeInterval(18 * 86_400),
                segments: [.init(app: "Brioche", minutes: 330, tint: coral), .init(app: "Pollen", minutes: 300, tint: indigo), .init(app: "Sextant", minutes: 187, tint: violet)]
            )
        )
    }
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), snapshot: Feed.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FeedEntry) -> Void) {
        let now = Date()
        completion(FeedEntry(date: now, snapshot: context.isPreview ? Feed.sample : Feed.load(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FeedEntry>) -> Void) {
        completion(Feed.timeline())
    }
}

// MARK: - The app a build widget is set on

struct WidgetAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = WidgetAppQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WidgetAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetAppEntity] {
        let wanted = Set(identifiers)
        return Feed.load(now: Date()).apps.filter { wanted.contains($0.id) }.map { WidgetAppEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [WidgetAppEntity] {
        Feed.load(now: Date()).apps.map { WidgetAppEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Latest Build"
    static let description = IntentDescription("The latest build of one app, or of all of them when none is chosen.")

    @Parameter(title: "App")
    var app: WidgetAppEntity?
}

struct LatestBuildProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), snapshot: Feed.sample)
    }

    func snapshot(for configuration: SelectAppIntent, in context: Context) async -> FeedEntry {
        let now = Date()
        return FeedEntry(date: now, snapshot: context.isPreview ? Feed.sample : Feed.load(now: now), appID: context.isPreview ? nil : configuration.app?.id)
    }

    func timeline(for configuration: SelectAppIntent, in context: Context) async -> Timeline<FeedEntry> {
        Feed.timeline(appID: configuration.app?.id)
    }
}

// MARK: - The widgets

struct LatestBuildWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LatestBuild", intent: SelectAppIntent.self, provider: LatestBuildProvider()) { entry in
            LatestBuildView(face: entry.snapshot.buildFace(appID: entry.appID))
        }
        .configurationDisplayName("Latest Build")
        .description("The state of the latest Xcode Cloud build, of one app or of all.")
        .supportedFamilies([.systemSmall])
    }
}

struct CycleRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CycleRing", provider: FeedProvider()) { entry in
            CycleRingSmallView(face: entry.snapshot.cycleFace, latest: entry.snapshot.latestBuild(appID: nil))
        }
        .configurationDisplayName("Cycle")
        .description("How much of the Xcode Cloud plan is used this cycle, app by app.")
        .supportedFamilies([.systemSmall])
    }
}

struct CycleBarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CycleBarAndBuilds", provider: FeedProvider()) { entry in
            CycleAndBuildsView(style: .bar, face: entry.snapshot.cycleFace, builds: entry.snapshot.recentBuilds(limit: 3), hasAccount: entry.snapshot.hasAccount)
        }
        .configurationDisplayName("Cycle and Builds")
        .description("The cycle as a bar, and the three latest builds.")
        .supportedFamilies([.systemMedium])
    }
}

struct CycleRingBuildsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CycleRingAndBuilds", provider: FeedProvider()) { entry in
            CycleAndBuildsView(style: .ring, face: entry.snapshot.cycleFace, builds: entry.snapshot.recentBuilds(limit: 3), hasAccount: entry.snapshot.hasAccount)
        }
        .configurationDisplayName("Cycle Ring and Builds")
        .description("The cycle as a ring, and the three latest builds.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct CumulusWidgets: WidgetBundle {
    var body: some Widget {
        LatestBuildWidget()
        CycleRingWidget()
        CycleBarWidget()
        CycleRingBuildsWidget()
    }
}
