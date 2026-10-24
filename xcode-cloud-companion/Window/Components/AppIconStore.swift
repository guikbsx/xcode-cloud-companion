import AppKit
import CryptoKit
import Observation

/// App icons on disk, one PNG per app and per icon: an icon already fetched is never asked for again.
nonisolated struct AppIconCache: Sendable {
    static let pixels = 128

    var directory: URL = AccountPaths.first.appIcons
    /// Fetches the image from Apple's image servers; nothing of the API key goes with it.
    var download: @Sendable (URL) async -> Data? = { url in
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    @concurrent func imageData(appID: String, icon: CIAppIcon) async -> Data? {
        guard Self.isSafe(appID) else { return nil }
        let file = directory.appending(path: "\(appID)-\(Self.fingerprint(of: icon)).png")
        if let cached = try? Data(contentsOf: file) {
            return cached
        }
        guard let url = icon.imageURL(pixels: Self.pixels), let data = await download(url), Self.isPNG(data) else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // The icon changed: the one it replaces goes.
        for name in (try? manager.contentsOfDirectory(atPath: directory.path())) ?? [] where name.hasPrefix("\(appID)-") {
            try? manager.removeItem(at: directory.appending(path: name))
        }
        try? data.write(to: file, options: [.atomic])
        return data
    }

    /// What is already on the disk, with no request and no waiting: nil when the icon was never fetched.
    func cachedImageData(appID: String, icon: CIAppIcon) -> Data? {
        guard Self.isSafe(appID) else { return nil }
        return try? Data(contentsOf: directory.appending(path: "\(appID)-\(Self.fingerprint(of: icon)).png"))
    }

    @concurrent func deleteAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    static func fingerprint(of icon: CIAppIcon) -> String {
        SHA256.hash(data: Data(icon.templateURL.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private static func isSafe(_ appID: String) -> Bool {
        !appID.isEmpty && appID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// A loaded icon and how to draw it.
struct AppArtwork {
    let image: NSImage
    let isMacIcon: Bool
}

extension AppIconCache {
    /// The icons of some products as they are on the disk, by product ID. Nothing is fetched: a product whose icon is not
    /// there yet is left out, and keeps its initial.
    func cachedArtwork(of productIDs: some Sequence<String>, in snapshot: BuildSnapshot) -> [String: AppArtwork] {
        var result: [String: AppArtwork] = [:]
        for productID in productIDs {
            guard let appID = snapshot.product(id: productID)?.appID, let icon = snapshot.appIcons[appID],
                  let data = cachedImageData(appID: appID, icon: icon), let image = NSImage(data: data)
            else { continue }
            result[productID] = AppArtwork(image: image, isMacIcon: icon.isMacIcon)
        }
        return result
    }
}

/// The icons the window shows, by app ID. An app without one keeps its coloured initial.
@Observable
final class AppIconStore {
    private(set) var images: [String: NSImage] = [:]
    private var shown: [String: CIAppIcon] = [:]
    private var loading: Set<String> = []
    private let cache: AppIconCache

    init(cache: AppIconCache = AppIconCache()) {
        self.cache = cache
    }

    func artwork(of product: CIProduct?, in snapshot: BuildSnapshot) -> AppArtwork? {
        guard let appID = product?.appID, let image = images[appID] else { return nil }
        return AppArtwork(image: image, isMacIcon: snapshot.appIcons[appID]?.isMacIcon ?? false)
    }

    /// Loaded icons keyed by what a view knows of an app: its product ID, or its product name.
    func artwork<Key: Hashable>(in snapshot: BuildSnapshot, by key: (CIProduct) -> Key) -> [Key: AppArtwork] {
        var result: [Key: AppArtwork] = [:]
        for product in snapshot.products {
            result[key(product)] = artwork(of: product, in: snapshot)
        }
        return result
    }

    /// Brings in the icons that are new or changed; a failed download changes nothing.
    func load(_ icons: [String: CIAppIcon]) async {
        for (appID, icon) in icons where shown[appID] != icon && !loading.contains(appID) {
            loading.insert(appID)
            if let data = await cache.imageData(appID: appID, icon: icon), let image = NSImage(data: data) {
                images[appID] = image
                shown[appID] = icon
            }
            loading.remove(appID)
        }
    }
}
