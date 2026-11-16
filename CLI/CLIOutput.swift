import Foundation

nonisolated enum CLIErrorCode: String, Codable, Sendable {
    case notFound = "NOT_FOUND"
    case ambiguous = "AMBIGUOUS"
    case noCache = "NO_CACHE"
    case usage = "USAGE"
    case appUnreachable = "APP_UNREACHABLE"
    case timedOut = "TIMEOUT"
    case `internal` = "INTERNAL"
    /// `run` and `testflight give` and `expire`: the key is read-only in the app, or Apple answered 403.
    case notAllowed = "NOT_ALLOWED"
    /// `run`: the app's cap on launches by agents; `testflight give` and `expire`: its cap on TestFlight changes; or Apple's hourly request limit.
    case rateLimited = "RATE_LIMITED"
    /// `run`: Apple understood and refused (a paused workflow, a branch no condition covers); `testflight`: Apple refused, or the build's state does not allow it. Its words are the message.
    case refused = "REFUSED"

    var exitCode: Int32 {
        switch self {
        case .notFound, .ambiguous: CLIExitCode.notFound
        case .noCache: CLIExitCode.noCache
        case .usage: CLIExitCode.usage
        case .appUnreachable: CLIExitCode.appUnreachable
        case .timedOut: CLIExitCode.timedOut
        case .internal, .refused: CLIExitCode.failure
        case .notAllowed: CLIExitCode.notAllowed
        case .rateLimited: CLIExitCode.rateLimited
        }
    }
}

/// Why a command could not answer, in a shape an agent can branch on.
nonisolated struct CLIFailure: Error, Equatable, Sendable, Encodable {
    var code: CLIErrorCode
    var message: String
    var suggestions: [String] = []

    static let noCache = CLIFailure(
        code: .noCache,
        message: "Cumulus has not synced any build yet.",
        suggestions: ["Open the Cumulus app and add your App Store Connect API key in Settings."]
    )

    static let appUnreachable = CLIFailure(
        code: .appUnreachable,
        message: "The Cumulus app is not answering.",
        suggestions: ["Open Cumulus, then try again."]
    )

    var json: String {
        CLIJSON.string(["error": self])
    }

    var text: String {
        ([message] + suggestions.map { "  \($0)" }).joined(separator: "\n") + "\n"
    }
}

/// What every answer carries next to its data: how fresh the cache is, and whether minutes in it are estimated.
nonisolated struct CLIMeta: Equatable, Sendable, Encodable {
    var lastSuccessfulSync: Date?
    var generatedAt: Date
    var cliVersion: String
    var isEstimate = false
    /// Whether the app answered on its socket: a cache it no longer feeds only gets older.
    var appRunning = false
    /// The name of the account the answer is about.
    var account: String?
    /// For the readable form only: with several accounts, the footer says which one was read.
    var showsAccount = false

    private enum CodingKeys: String, CodingKey {
        case lastSuccessfulSync, generatedAt, cliVersion, isEstimate, appRunning, account
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Always present, null before the first sync: an agent reads the cache's age from it.
        try container.encode(lastSuccessfulSync, forKey: .lastSuccessfulSync)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(appRunning, forKey: .appRunning)
        if isEstimate {
            try container.encode(true, forKey: .isEstimate)
        }
        try container.encodeIfPresent(account, forKey: .account)
    }
}

nonisolated struct CLIEnvelope<Payload: Encodable>: Encodable {
    var data: Payload
    var meta: CLIMeta
}

nonisolated enum CLIJSON {
    static func data(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func string(_ value: some Encodable) -> String {
        String(decoding: data(value), as: UTF8.self) + "\n"
    }
}

nonisolated enum CLINumber {
    /// Minutes to one decimal, the precision of the contract.
    static func minutes(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func fraction(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// The share of a plan as the whole percentage shown to people, given back as a fraction (0.54). The minutes are
    /// taken at the precision of the contract first: the app, which has the exact minutes, and the command, which has
    /// the published ones, then round the same figures and cannot disagree.
    static func wholePercentFraction(usedMinutes: Double, quotaMinutes: Double) -> Double {
        let quota = minutes(quotaMinutes)
        guard quota > 0 else { return 0 }
        return (minutes(usedMinutes) / quota * 100).rounded() / 100
    }

    static func seconds(_ value: TimeInterval) -> Int {
        Int(value.rounded())
    }
}
