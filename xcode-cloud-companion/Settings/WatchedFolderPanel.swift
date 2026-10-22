import AppKit

/// The standard open panel that asks for the folder where usage exports are saved.
enum WatchedFolderPanel {
    static func choose() -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = WatchedFolder.suggestedFolder
        panel.prompt = String(localized: "Watch", comment: "Button of the panel that picks the folder where usage exports are saved")
        panel.message = String(localized: "Choose the folder where you save App Store Connect’s usage exports. Cumulus imports the ones it finds there.")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
