import Foundation

nonisolated struct BuildsQuery: Equatable, Sendable {
    static let defaultLimit = 10
    static let maximumLimit = 100

    var app: String?
    var failed = false
    var running = false
    var limit = BuildsQuery.defaultLimit
    var since: Date?
}

nonisolated enum UsageBreakdown: String, Equatable, Sendable, CaseIterable {
    case summary
    case byApp
    case byWorkflow
    case daily
}

/// A question the cache can answer; the command line and the MCP server both ask through it.
nonisolated enum CLIQuery: Equatable, Sendable {
    case status
    case apps
    case builds(BuildsQuery)
    /// `fetch` asks the running app for the build's issues and tests when the cache lacks them.
    case build(reference: String, fetch: Bool)
    case workflows(app: String?)
    case usage(UsageBreakdown)
}

nonisolated enum CLIReference {
    /// An app by its product id, its bundle ID or its name, whatever the case.
    static func product(_ reference: String, in snapshot: BuildSnapshot) throws(CLIFailure) -> CIProduct {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let exact = snapshot.products.first(where: { $0.id == wanted }) {
            return exact
        }
        let folded = wanted.lowercased()
        let matches = snapshot.products.filter {
            $0.name.lowercased() == folded || $0.appName?.lowercased() == folded || $0.bundleID?.lowercased() == folded
        }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw CLIFailure(
                code: .notFound, message: "No app matches '\(wanted)'.",
                suggestions: snapshot.products.map(\.name).sorted().map { "Known app: \($0)" }
            )
        default:
            throw CLIFailure(
                code: .ambiguous, message: "Several apps match '\(wanted)'.",
                suggestions: matches.map { "\($0.name) (\($0.bundleID ?? $0.id))" }
            )
        }
    }

    /// A build by its run id, as `App#42`, or by its number alone when only one app has it.
    static func run(_ reference: String, in snapshot: BuildSnapshot) throws(CLIFailure) -> CIBuildRun {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let exact = snapshot.runs.first(where: { $0.id == wanted }) {
            return exact
        }
        if let separator = wanted.lastIndex(of: "#"), let number = Int(wanted[wanted.index(after: separator)...]) {
            let product = try product(String(wanted[..<separator]), in: snapshot)
            guard let run = snapshot.runs.first(where: { $0.productID == product.id && $0.number == number }) else {
                throw CLIFailure(
                    code: .notFound, message: "\(product.name) has no build \(number) in the cache.",
                    suggestions: ["Run 'cumulus builds --app \"\(product.name)\"' to list its recent builds."]
                )
            }
            return run
        }
        if let number = Int(wanted) {
            let matches = snapshot.runs.filter { $0.number == number }
            let names = Dictionary(snapshot.products.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            switch matches.count {
            case 1:
                return matches[0]
            case 0:
                break
            default:
                throw CLIFailure(
                    code: .ambiguous, message: "Several apps have a build \(number).",
                    suggestions: matches.map { "\(names[$0.productID] ?? $0.productID)#\(number)" }
                )
            }
        }
        throw CLIFailure(
            code: .notFound, message: "No build matches '\(wanted)'.",
            suggestions: ["Use 'App#42' or a build run id; 'cumulus builds' lists both."]
        )
    }
}

nonisolated enum CLIStatusWord {
    static func word(progress: CIExecutionProgress, completion: CICompletionStatus?) -> String {
        switch (progress, completion) {
        case (.pending, _): "pending"
        case (.running, _): "running"
        case (_, .succeeded?): "succeeded"
        case (_, .failed?): "failed"
        case (_, .errored?): "errored"
        case (_, .canceled?): "canceled"
        case (_, .skipped?): "skipped"
        case (_, .unknown(let raw)?) where !raw.isEmpty: raw.lowercased()
        default: "finished"
        }
    }
}

nonisolated enum CLISince {
    /// `7d`, `24h`, `30m` back from now, or an ISO 8601 date or day.
    static func date(_ text: String, now: Date) -> Date? {
        if let unit = text.last, let amount = Double(text.dropLast()), amount >= 0 {
            switch unit {
            case "d": return now.addingTimeInterval(-amount * 86_400)
            case "h": return now.addingTimeInterval(-amount * 3_600)
            case "m": return now.addingTimeInterval(-amount * 60)
            default: break
            }
        }
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().year().month().day().parse(text)
    }
}
