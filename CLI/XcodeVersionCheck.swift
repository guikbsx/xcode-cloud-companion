import Foundation

/// An Xcode version Xcode Cloud offers, as Apple lists them: `name` is “Xcode 27.1” or “Xcode 27.2 beta 2”, `version` the bare number.
nonisolated struct CIXcodeVersion: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
}

/// Whether a workflow stays on an older Xcode than the newest public one Xcode Cloud offers. Apple marks no version as
/// the latest nor as a beta: the newest is the highest number whose name does not say it is a prerelease.
nonisolated enum XcodeVersionCheck {
    struct Warning: Equatable, Sendable {
        /// The workflow's version, as named.
        let current: String
        /// The newest public version, as named.
        let latest: String
    }

    static func isPrerelease(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["beta", "release candidate", " rc", "seed"].contains { lowered.contains($0) } || lowered.hasSuffix("rc")
    }

    /// The first run of dotted numbers: “27.1” from “Xcode 27.1 (27B45)”, “27.1” from “27.1”.
    static func components(_ version: String) -> [Int] {
        guard let range = version.firstRange(of: /\d+(\.\d+)*/) else { return [] }
        return version[range].split(separator: ".").compactMap { Int($0) }
    }

    /// Numbers compared place by place, a missing place counting as zero: 27.1 is above 27.0.5 and equal to 27.1.0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func latestPublic(in versions: [CIXcodeVersion]) -> CIXcodeVersion? {
        versions
            .filter { !isPrerelease($0.name) && !components($0.version).isEmpty }
            .max { compare($0.version, $1.version) == .orderedAscending }
    }

    /// A warning when the workflow's version is strictly below the newest public one; nothing when either is unknown.
    static func warning(version: String?, name: String?, among versions: [CIXcodeVersion]) -> Warning? {
        guard let version, !components(version).isEmpty, let latest = latestPublic(in: versions),
              compare(version, latest.version) == .orderedAscending
        else { return nil }
        return Warning(current: name ?? version, latest: latest.name)
    }
}
