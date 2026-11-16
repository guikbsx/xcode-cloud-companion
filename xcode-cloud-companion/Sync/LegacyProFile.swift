import Foundation

nonisolated enum LegacyProFile {
    static let fileName = "Pro.json"

    static func remove(in directory: URL = SharedContainer.applicationSupport, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory.appending(path: fileName))
    }
}
