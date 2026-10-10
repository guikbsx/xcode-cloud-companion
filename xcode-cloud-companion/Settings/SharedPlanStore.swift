import Foundation

/// The plan lives in the app's preferences, out of the `cumulus` command's reach: this copy in the app group is the one it reads.
nonisolated struct SharedPlanStore: Sendable {
    private struct File: Codable {
        var hours: Int
        var resetAnchor: Date
    }

    var fileURL: URL = SharedContainer.applicationSupport.appending(path: "UsagePlan.json")

    @concurrent func load() async -> UsagePlan? {
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return UsagePlan(hours: file.hours, resetAnchor: file.resetAnchor)
    }

    /// A nil plan removes the copy: no reset date is set, or the key was removed.
    @concurrent func save(_ plan: UsagePlan?) async {
        guard let plan else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(File(hours: plan.hours, resetAnchor: plan.resetAnchor)).write(to: fileURL, options: [.atomic])
    }
}
