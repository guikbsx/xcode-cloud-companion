import Foundation

// What the app keeps in an account's folder of the shared container and the `cumulus` command reads back: the file of each
// app's TestFlight builds and the file of its groups. Nothing in this file may import AppKit or SwiftUI.

nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A TestFlight group of an app, as `GET /v1/apps/{id}/betaGroups` lists it.
nonisolated struct BetaGroup: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var isInternal: Bool
    /// An internal group that gets every build by itself (`hasAccessToAllBuilds`): it is never added to nor taken from.
    var receivesEveryBuild: Bool
    /// Read apart, once a session; nil while unknown, and then not said.
    var testerCount: Int?

    /// The groups of the card's skeleton: typical names, no tester count.
    static let placeholders = [
        BetaGroup(id: "g1", name: "Team", isInternal: true, receivesEveryBuild: true, testerCount: 4),
        BetaGroup(id: "g2", name: "QA", isInternal: true, receivesEveryBuild: false, testerCount: 2),
        BetaGroup(id: "g3", name: "Public beta", isInternal: false, receivesEveryBuild: false, testerCount: 128),
    ]
}

/// What the last read of an app's groups said.
nonisolated struct BetaGroupsReading: Codable, Sendable, Equatable {
    var appID: String
    var groups: [BetaGroup]
    var readAt: Date
}

/// Every app's groups, in one file of the account's folder: it goes with the account.
nonisolated struct BetaGroupsFile: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var schemaVersion = BetaGroupsFile.currentVersion
    /// By App Store Connect app.
    var readings: [String: BetaGroupsReading] = [:]
}

nonisolated struct BetaGroupsCache: Sendable {
    var fileURL: URL

    @concurrent func load() async -> BetaGroupsFile? {
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(BetaGroupsFile.self, from: data),
              file.schemaVersion == BetaGroupsFile.currentVersion
        else { return nil }
        return file
    }

    @concurrent func save(_ file: BetaGroupsFile) async {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: fileURL, options: [.atomic])
    }

    @concurrent func delete() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Every app's last reading, in one file of the account's folder: it goes with the account.
nonisolated struct TestFlightFile: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var schemaVersion = TestFlightFile.currentVersion
    /// By Xcode Cloud product.
    var readings: [String: TestFlightReading] = [:]
}

nonisolated struct TestFlightCache: Sendable {
    var fileURL: URL

    @concurrent func load() async -> TestFlightFile? {
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(TestFlightFile.self, from: data),
              file.schemaVersion == TestFlightFile.currentVersion
        else { return nil }
        return file
    }

    @concurrent func save(_ file: TestFlightFile) async {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: fileURL, options: [.atomic])
    }

    @concurrent func delete() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
