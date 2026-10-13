import AppIntents
import Foundation

/// A build, as Shortcuts and Spotlight see it.
nonisolated struct BuildEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Build"
    static let defaultQuery = BuildEntityQuery()

    var id: String
    var reference: String
    var summary: String
    var app: String
    var number: Int?
    var status: String
    var workflow: String?
    var durationMinutes: Double?
    var link: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(reference)", subtitle: "\(summary)")
    }

    init(_ build: IntentAnswers.Build, summary: String) {
        id = build.id
        reference = build.reference
        self.summary = summary
        app = build.app
        number = build.number
        status = build.status.label
        workflow = build.workflow
        durationMinutes = build.durationMinutes
        link = build.link
    }
}

nonisolated struct BuildEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BuildEntity] {
        let answers = IntentAnswers.live
        let wanted = Set(identifiers)
        return try await answers.builds(limit: BuildsQuery.maximumLimit).filter { wanted.contains($0.id) }.map { BuildEntity($0, summary: answers.sentence(for: $0)) }
    }

    func suggestedEntities() async throws -> [BuildEntity] {
        let answers = IntentAnswers.live
        return try await answers.builds(limit: 10).map { BuildEntity($0, summary: answers.sentence(for: $0)) }
    }
}

/// An app Cumulus follows, to ask about its builds alone.
nonisolated struct FollowedAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = FollowedAppQuery()

    var id: String
    /// The product's name: what the caches are asked by.
    var name: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(_ app: IntentAnswers.App) {
        id = app.id
        name = app.name
        displayName = app.displayName
    }
}

nonisolated struct FollowedAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FollowedAppEntity] {
        let wanted = Set(identifiers)
        return try await IntentAnswers.live.apps().filter { wanted.contains($0.id) }.map(FollowedAppEntity.init)
    }

    func suggestedEntities() async throws -> [FollowedAppEntity] {
        try await IntentAnswers.live.apps().map(FollowedAppEntity.init)
    }
}

/// Not `nonisolated` as a whole: a parameter is kept by a reference the main actor owns. What the system reads
/// without running the intent is.
struct LatestBuildIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Get Latest Build"
    nonisolated static let description = IntentDescription("The most recent Xcode Cloud build Cumulus knows, of every app or of one.")

    @Parameter(title: "App")
    var app: FollowedAppEntity?

    /// The system makes an intent wherever it is, before running it.
    nonisolated init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<BuildEntity> & ProvidesDialog {
        let answers = IntentAnswers.live
        let build = try await answers.latestBuild(app: app?.id)
        let sentence = answers.sentence(for: build)
        return .result(value: BuildEntity(build, summary: sentence), dialog: "\(sentence)")
    }
}

nonisolated struct RunningBuildsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Running Builds"
    static let description = IntentDescription("The Xcode Cloud builds that are waiting or running right now.")

    func perform() async throws -> some IntentResult & ReturnsValue<[BuildEntity]> & ProvidesDialog {
        let answers = IntentAnswers.live
        let builds = try await answers.builds(running: true, limit: 20)
        let entities = builds.map { BuildEntity($0, summary: answers.sentence(for: $0)) }
        guard !builds.isEmpty else {
            return .result(value: entities, dialog: "No build is running.")
        }
        let names = builds.map(\.reference).formatted(.list(type: .and))
        return .result(value: entities, dialog: "Builds running: \(names).")
    }
}

nonisolated struct CycleUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Cycle Usage"
    static let description = IntentDescription("How much of the Xcode Cloud plan is used this cycle, as Cumulus estimates it.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = try await IntentAnswers.live.usageSentence()
        return .result(value: sentence, dialog: "\(sentence)")
    }
}

nonisolated struct CumulusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LatestBuildIntent(),
            phrases: ["Latest build in \(.applicationName)", "Get the latest \(.applicationName) build"],
            shortTitle: "Latest Build", systemImageName: "hammer"
        )
        AppShortcut(
            intent: CycleUsageIntent(),
            phrases: ["\(.applicationName) usage", "Xcode Cloud usage in \(.applicationName)"],
            shortTitle: "Cycle Usage", systemImageName: "gauge.with.dots.needle.50percent"
        )
        AppShortcut(
            intent: RunningBuildsIntent(),
            phrases: ["Running builds in \(.applicationName)"],
            shortTitle: "Running Builds", systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
