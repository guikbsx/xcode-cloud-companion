import Foundation
import Observation

/// Where each app's repository is cloned on this Mac, by Xcode Cloud product name. The sandbox opens a folder only when
/// the user picked it in a panel: the grant is kept as a security-scoped bookmark, in the account's own preferences.
@Observable
final class LocalRepositories {
    private let defaults: UserDefaults
    private let key: String
    /// Resolved from the bookmarks once; a folder that moved or vanished is dropped.
    private(set) var roots: [String: URL] = [:]

    init(accountID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = AccountDefaults.key(AccountDefaults.localRepositories, accountID: accountID)
        for (product, data) in bookmarks {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale), !isStale {
                roots[product] = url
            }
        }
    }

    func root(for product: String) -> URL? {
        roots[product]
    }

    /// Keeps a folder the user just picked; false when the sandbox gives no bookmark for it.
    @discardableResult
    func set(_ url: URL, for product: String) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        var saved = bookmarks
        saved[product] = data
        defaults.set(saved, forKey: key)
        roots[product] = url
        return true
    }

    func forget(_ product: String) {
        var saved = bookmarks
        saved.removeValue(forKey: product)
        defaults.set(saved, forKey: key)
        roots.removeValue(forKey: product)
    }

    /// Runs `body` with the folder open to the sandbox; nil when no folder is known for the product.
    func withAccess<T>(to product: String, _ body: (URL) -> T) -> T? {
        guard let url = roots[product] else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return body(url)
    }

    private var bookmarks: [String: Data] {
        defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}
