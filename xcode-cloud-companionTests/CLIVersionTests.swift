import Foundation
import Testing
@testable import XcodeCloudCompanion

struct CLIVersionTests {
    @Test func throughASymbolicLinkTheVersionComesFromTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Cumulus.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.cumulus",
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "17",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "Helpers/cumulus")
        try Data().write(to: executable)
        let link = root.appending(path: "bin/cumulus")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        let info = CLIEnvironment.versionInfo(main: [:], executable: link)

        #expect(info["CFBundleShortVersionString"] as? String == "1.2.0")
        #expect(info["CFBundleVersion"] as? String == "17")
    }

    @Test func anEmbeddedVersionIsKept() {
        let main: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "3"]

        let info = CLIEnvironment.versionInfo(main: main, executable: URL(filePath: "/usr/local/bin/cumulus"))

        #expect(info["CFBundleShortVersionString"] as? String == "1.0")
    }

    @Test func outsideAnAppNothingIsMadeUp() {
        let info = CLIEnvironment.versionInfo(main: nil, executable: URL(filePath: "/usr/local/bin/cumulus"))

        #expect(info.isEmpty)
    }
}
