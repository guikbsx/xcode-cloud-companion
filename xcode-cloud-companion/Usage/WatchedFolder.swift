import Foundation
import Observation

/// The folder where the user saves App Store Connect's usage exports, which Cumulus watches to import them. It is one
/// folder for every account, since the import is shared. Nothing is watched until the user picks one in a panel: the
/// sandbox opens a folder only then, and the grant is kept as a security-scoped bookmark.
@Observable
final class WatchedFolder {
    static let defaultsKey = "usage.watchedFolder"

    private let defaults: UserDefaults
    /// The folder the bookmark leads to, nil when none was chosen, or when it moved out of reach or vanished.
    private(set) var url: URL?
    /// Called after the folder changed or was forgotten.
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        if isStale {
            guard let fresh = Self.bookmark(for: resolved) else {
                defaults.removeObject(forKey: Self.defaultsKey)
                return
            }
            defaults.set(fresh, forKey: Self.defaultsKey)
        }
        url = resolved
    }

    /// Keeps a folder the user just picked; false when the sandbox gives no bookmark for it.
    @discardableResult
    func choose(_ folder: URL) -> Bool {
        guard let data = Self.bookmark(for: folder) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        url = folder
        onChange?()
        return true
    }

    func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
        guard url != nil else { return }
        url = nil
        onChange?()
    }

    /// The user's real Downloads folder, where the panel opens: in the sandbox the system's answer is inside the container.
    static var suggestedFolder: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(filePath: String(cString: home), directoryHint: .isDirectory).appending(path: "Downloads", directoryHint: .isDirectory)
    }

    private static func bookmark(for folder: URL) -> Data? {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing { folder.stopAccessingSecurityScopedResource() }
        }
        return try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
