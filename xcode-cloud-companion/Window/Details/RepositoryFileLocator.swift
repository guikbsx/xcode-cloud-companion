import Foundation

/// From the path Apple reports, which is the build machine's (`/Volumes/workspace/repository/Sources/App.swift`), to the
/// same file in the local clone. Nothing outside the clone is ever opened.
nonisolated enum RepositoryFileLocator {
    static let checkoutMarker = "/repository/"

    /// The file's path inside the repository: what follows `repository/` on the build machine, or the path itself when it
    /// is already relative. nil for any other absolute path, and for a path that climbs out.
    static func relativePath(of path: String) -> String? {
        let relative: Substring
        if let marker = path.range(of: checkoutMarker) {
            relative = path[marker.upperBound...]
        } else if !path.hasPrefix("/") {
            relative = Substring(path)
        } else {
            return nil
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(".."), !components.contains("~") else { return nil }
        return components.joined(separator: "/")
    }

    /// The file in `root`, when `path` names one inside the repository.
    static func localURL(for path: String, in root: URL) -> URL? {
        guard let relative = relativePath(of: path) else { return nil }
        let file = root.appending(path: relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return file.path(percentEncoded: false).hasPrefix(prefix) ? file : nil
    }
}
