import Foundation

/// Where the app keeps what the `cumulus` command reads: the app group container, the one place both sandboxes reach.
nonisolated enum SharedContainer {
    /// Prefixed by the team rather than `group.`: macOS grants it without a provisioning profile, and it keeps the socket path short.
    static let groupIdentifier = "4HYT2U85R2.com.guik.cumulus"

    static let groupContainer: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)

    static let applicationSupport: URL = resolve(groupContainer: groupContainer, fallback: .applicationSupportDirectory)

    /// Where the app listens for the `cumulus` command. At the container's root: a socket path holds 103 bytes at most.
    /// Nil when the container is out of reach, since the sandbox allows a socket nowhere else.
    static let socketPath: String? = socketPath(groupContainer: groupContainer, applicationSupport: applicationSupport)

    static func socketPath(groupContainer: URL?, applicationSupport: URL) -> String? {
        guard let groupContainer, applicationSupport.path(percentEncoded: false).hasPrefix(groupContainer.path(percentEncoded: false)) else { return nil }
        return groupContainer.appending(path: "ipc.sock").path(percentEncoded: false)
    }

    /// The group container when this process may write to it, the process's own Application Support otherwise
    /// (a build without the entitlement).
    static func resolve(groupContainer: URL?, fallback: URL, fileManager: FileManager = .default) -> URL {
        guard let groupContainer else { return fallback }
        let directory = groupContainer.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return fallback
        }
    }
}

/// Moves the caches from where an earlier version kept them (before the app group, then before accounts), once:
/// what is already at the destination is never replaced.
nonisolated struct CacheMigration: Sendable {
    static let itemNames = ["BuildCache.json", "UsageLedger.json", "BuildDetails", "WorkflowDetails"]

    var source: URL = .applicationSupportDirectory
    var destination: URL = SharedContainer.applicationSupport
    var itemNames = CacheMigration.itemNames

    @concurrent func run() async {
        let fileManager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in itemNames {
            move(source.appending(path: name), to: destination.appending(path: name), fileManager: fileManager)
        }
    }

    private func move(_ item: URL, to target: URL, fileManager: FileManager) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: item.path(percentEncoded: false), isDirectory: &isDirectory) else { return }
        guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else {
            try? fileManager.moveItem(at: item, to: target)
            return
        }
        guard isDirectory.boolValue else { return }
        for child in (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
            move(child, to: target.appending(path: child.lastPathComponent), fileManager: fileManager)
        }
        if ((try? fileManager.contentsOfDirectory(atPath: item.path(percentEncoded: false))) ?? [""]).isEmpty {
            try? fileManager.removeItem(at: item)
        }
    }
}
