import AppKit
import SwiftUI

/// Opens a build's file in Xcode, at its line. Apple names the file as the build machine saw it; the local clone, picked
/// once per app in a panel, says where it is here.
struct SourceOpener {
    let repositories: LocalRepositories
    /// The Xcode Cloud product name, the key of the clone; `appName` is the one shown.
    let product: String
    let appName: String

    static var xcodeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
    }

    /// Opens the file; the message says why it could not be.
    func open(path: String, line: Int?) -> String? {
        guard let xcode = Self.xcodeURL else { return String(localized: "Xcode isn’t installed on this Mac.") }
        guard let relative = RepositoryFileLocator.relativePath(of: path) else {
            return String(localized: "This file isn’t in the repository: \(path)")
        }
        if repositories.root(for: product) == nil {
            guard let picked = Self.chooseRepository(appName: appName, expecting: relative) else { return nil }
            guard repositories.set(picked, for: product) else { return String(localized: "This folder couldn’t be kept for later. Try another one.") }
        }
        let failure: String?? = repositories.withAccess(to: product) { root -> String? in
            guard let file = RepositoryFileLocator.localURL(for: path, in: root) else { return String(localized: "This file isn’t in the repository: \(path)") }
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                return String(localized: "\(relative) isn’t in \(root.lastPathComponent). Another branch is checked out there, or the clone is elsewhere: change it in Settings › Accounts.")
            }
            Self.open(file, line: line, xcode: xcode)
            return nil
        }
        return failure ?? nil
    }

    /// Xcode's own `xed` selects the line; `/usr/bin/xed` goes through `xcrun`, which refuses to run in a sandbox
    /// (verified on 11/10/2026). Should it fail, the file still opens, without the line.
    static func open(_ file: URL, line: Int?, xcode: URL) {
        let process = Process()
        process.executableURL = xcode.appending(path: "Contents/Developer/usr/bin/xed")
        process.arguments = (line.map { ["-l", String($0)] } ?? []) + [file.path(percentEncoded: false)]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open([file], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Asks for the app's clone: the folder that holds `expecting`, when a file is known.
    static func chooseRepository(appName: String, expecting relative: String? = nil) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button of the panel that picks an app's local repository")
        panel.message = relative.map { String(localized: "Choose the local repository of \(appName): the folder that holds \($0).") }
            ?? String(localized: "Choose the local repository of \(appName).")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// How a results row reaches the opener: set by the build sheet for the build's own app.
struct SourceOpening {
    let open: @MainActor (String, Int?) -> String?
}

extension EnvironmentValues {
    @Entry var sourceOpening: SourceOpening?
}
