import Foundation

/// Whether Cumulus Pro is open, as the app last wrote it. The `cumulus` command sees neither StoreKit nor the app's
/// preferences: this file in the shared folder is all it knows. It can be edited by hand; what writes to Apple is
/// checked again by the app itself.
nonisolated struct ProStatus: Codable, Equatable, Sendable {
    var isActive: Bool
    var writtenAt: Date
}

nonisolated struct ProStatusStore: Sendable {
    static let fileName = "Pro.json"

    var fileURL: URL

    /// `directory` is the root of the shared folder, where `Accounts.json` is.
    init(directory: URL = SharedContainer.applicationSupport) {
        fileURL = directory.appending(path: Self.fileName)
    }

    func load() -> ProStatus? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProStatus.self, from: data)
    }

    func save(_ status: ProStatus) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(status).write(to: fileURL, options: [.atomic])
    }

    /// Writes the state when the file does not say it already: the app calls this at launch and after each reading.
    func record(isActive: Bool, now: Date) {
        guard load()?.isActive != isActive else { return }
        save(ProStatus(isActive: isActive, writtenAt: now))
    }
}

/// What the command and the MCP server ask before answering anything but `cumulus status`.
nonisolated enum ProGate {
    /// Why the answer is refused; nil with Cumulus Pro. A missing or unreadable file is no Pro: the app has to say so.
    static func refusal(in directory: URL, overMCP: Bool = false) -> CLIFailure? {
        let free = overMCP ? [] : ["'cumulus status' works without Cumulus Pro."]
        guard let status = ProStatusStore(directory: directory).load() else {
            return CLIFailure(
                code: .proRequired,
                message: "Cumulus Pro is required, and the app has not said yet whether it is active.",
                suggestions: ["Open the Cumulus app, then try again."] + free
            )
        }
        guard !status.isActive else { return nil }
        return CLIFailure(
            code: .proRequired,
            message: "Cumulus Pro is required.",
            suggestions: ["Ask the user to open Cumulus › Settings › Cumulus Pro, to start the free trial or restore a purchase."] + free
        )
    }
}
