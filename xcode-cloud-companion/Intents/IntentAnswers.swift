import Foundation

/// What Siri, Spotlight and Shortcuts are told: read from the caches the app keeps, through the same questions as
/// the `cumulus` command, and never from Apple.
nonisolated struct IntentAnswers: Sendable {
    var environment: CLIEnvironment
    var locale: Locale = .autoupdatingCurrent

    /// The app's own caches. No socket: an intent runs inside the app, it has nobody to ask.
    static var live: IntentAnswers {
        let info = Bundle.main.infoDictionary ?? [:]
        return IntentAnswers(environment: CLIEnvironment(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            directory: SharedContainer.applicationSupport
        ))
    }

    /// Why there is nothing to answer, in words for the person who asked.
    struct Failure: Error, Equatable, Sendable, CustomLocalizedStringResourceConvertible {
        enum Reason: Equatable, Sendable {
            case noData
            case noBuild
            case unknownApp(String)
        }

        var reason: Reason

        var localizedStringResource: LocalizedStringResource {
            switch reason {
            case .noData: "Cumulus has no build yet. Open the app and add your App Store Connect API key."
            case .noBuild: "Cumulus knows no build for this."
            case .unknownApp(let name): "Cumulus follows no app named \(name)."
            }
        }
    }

    struct Build: Equatable, Sendable {
        var id: String
        var reference: String
        var app: String
        var number: Int?
        var status: BuildStatus
        var isRunning: Bool
        var workflow: String?
        var durationMinutes: Double?
        var finishedOrCreated: Date?
        var link: URL?
    }

    struct App: Equatable, Sendable {
        var id: String
        /// The product's name, which is what the caches and the references use.
        var name: String
        var displayName: String
    }

    // MARK: - Questions

    func apps() async throws(Failure) -> [App] {
        guard case .apps(let apps) = try await report(.apps) else { return [] }
        return apps.map { App(id: $0.id, name: $0.name, displayName: $0.storeName ?? $0.name) }
    }

    /// The newest builds first; `app` is a product's name or id.
    func builds(app: String? = nil, running: Bool = false, limit: Int = 10) async throws(Failure) -> [Build] {
        var query = BuildsQuery()
        query.app = app
        query.running = running
        query.limit = limit
        guard case .builds(let builds) = try await report(.builds(query), app: app) else { return [] }
        return builds.map(Self.build)
    }

    func latestBuild(app: String? = nil) async throws(Failure) -> Build {
        guard let build = try await builds(app: app, limit: 1).first else { throw Failure(reason: .noBuild) }
        return build
    }

    /// One sentence on the cycle. The figure is an estimate unless every minute of it was billed by Apple, and says so.
    func usageSentence() async throws(Failure) -> String {
        guard case .status(let status) = try await report(.status) else { throw Failure(reason: .noData) }
        guard let usage = status.usage else {
            return String(localized: LocalizedStringResource("No plan is set in Cumulus: add the reset date in Settings to follow the cycle.", locale: locale))
        }
        if usage.measurement.isMeasuring {
            return String(localized: LocalizedStringResource("Cumulus is still measuring the builds of this cycle.", locale: locale))
        }
        let used = UsageFormat.minutes(usage.usedMinutes, locale: locale)
        let plan = UsageFormat.minutes(usage.quotaMinutes, locale: locale)
        let percent = UsageFormat.percent(CLINumber.wholePercentFraction(usedMinutes: usage.usedMinutes, quotaMinutes: usage.quotaMinutes), locale: locale)
        let reset = UsageFormat.day(usage.resetDate, locale: locale)
        return usage.estimatedMinutes > 0
            ? String(localized: LocalizedStringResource("About \(used) of \(plan) used (\(percent)), an estimate. The cycle resets on \(reset).", locale: locale))
            : String(localized: LocalizedStringResource("\(used) of \(plan) used (\(percent)). The cycle resets on \(reset).", locale: locale))
    }

    /// A build in one sentence: “Pollen #394 succeeded 5 minutes ago, in 14 min.”
    func sentence(for build: Build) -> String {
        let state = build.status.label
        var parts = [String(localized: LocalizedStringResource("\(build.reference): \(state)", locale: locale))]
        if let date = build.finishedOrCreated {
            parts.append(UsageFormat.relative(date, now: environment.now(), locale: locale))
        }
        if let minutes = build.durationMinutes, !build.isRunning {
            parts.append(UsageFormat.minutes(minutes, locale: locale))
        }
        return UsageFormat.dotted(parts, locale: locale)
    }

    // MARK: - Private

    private func report(_ query: CLIQuery, app: String? = nil) async throws(Failure) -> CLIReport {
        do {
            return try await CLIQueryRunner(environment: environment).run(query).report
        } catch {
            switch error.code {
            case .notFound, .ambiguous: throw Failure(reason: app.map { .unknownApp($0) } ?? .noBuild)
            default: throw Failure(reason: .noData)
            }
        }
    }

    private static func build(_ output: BuildOutput) -> Build {
        let isRunning = output.status == "running" || output.status == "pending"
        return Build(
            id: output.id,
            reference: output.reference ?? output.app,
            app: output.app,
            number: output.number,
            status: status(named: output.status),
            isRunning: isRunning,
            workflow: output.workflow,
            durationMinutes: output.durationSeconds.map { Double($0) / 60 },
            finishedOrCreated: output.finishedDate ?? output.startedDate ?? output.createdDate,
            link: CumulusURL.build(id: output.id)
        )
    }

    /// The names the command gives a build's state, back to the state the interface draws.
    static func status(named name: String) -> BuildStatus {
        switch name {
        case "pending", "running": .running
        case "succeeded": .succeeded
        case "failed": .failed
        case "errored": .errored
        case "canceled": .canceled
        case "skipped": .skipped
        default: .finished
        }
    }
}
