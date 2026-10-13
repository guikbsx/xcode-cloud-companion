import Foundation
import Testing
@testable import XcodeCloudCompanion

struct MCPBundleTests {
    private let command = URL(filePath: "/Applications/Cumulus.app/Contents/Helpers/cumulus")

    @Test func theManifestNamesEveryToolAndRunsTheLauncherThroughTheShell() throws {
        let data = try #require(MCPBundle.manifest(appVersion: "1.0"))
        let manifest = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(manifest["manifest_version"]?.stringValue == "0.3")
        #expect(manifest["name"]?.stringValue == "cumulus" && manifest["display_name"]?.stringValue == "Cumulus")
        #expect(manifest["version"]?.stringValue == "1.0.0")
        #expect(manifest["description"]?.stringValue?.isEmpty == false)
        #expect(manifest["author"]?["name"]?.stringValue?.isEmpty == false)
        #expect(manifest["server"]?["type"]?.stringValue == "binary")
        #expect(manifest["server"]?["entry_point"]?.stringValue == "server/launch.sh")
        #expect(manifest["server"]?["mcp_config"]?["command"]?.stringValue == "/bin/sh")
        #expect(manifest["server"]?["mcp_config"]?["args"] == .array([.string("${__dirname}/server/launch.sh")]))
        #expect(manifest["compatibility"]?["platforms"] == .array([.string("darwin")]))
        guard case .array(let tools)? = manifest["tools"] else {
            Issue.record("the manifest lists no tools")
            return
        }
        #expect(tools.compactMap { $0["name"]?.stringValue } == MCPTools.all.map(\.name))
        #expect(tools.allSatisfy { $0["description"]?.stringValue?.isEmpty == false })
    }

    @Test func theVersionAlwaysHasThreeNumbers() {
        #expect(MCPBundle.semanticVersion("1.0") == "1.0.0")
        #expect(MCPBundle.semanticVersion("2") == "2.0.0")
        #expect(MCPBundle.semanticVersion("1.2.3") == "1.2.3")
        #expect(MCPBundle.semanticVersion("1.2.3.4") == "1.2.3")
        #expect(MCPBundle.semanticVersion("1.1b2") == "1.1.0")
        #expect(MCPBundle.semanticVersion("") == "0.0.0")
    }

    @Test func theLauncherRunsTheAppsCommandWhereverTheAppIs() {
        #expect(MCPBundle.launcher(command: command) == "#!/bin/sh\nexec '/Applications/Cumulus.app/Contents/Helpers/cumulus' mcp\n")
        let odd = URL(filePath: "/Users/o'neil/My Apps/Cumulus.app/Contents/Helpers/cumulus")
        #expect(MCPBundle.launcher(command: odd) == "#!/bin/sh\nexec '/Users/o'\\''neil/My Apps/Cumulus.app/Contents/Helpers/cumulus' mcp\n")
    }

    @Test func theArchiveIsAZipThatGivesBackItsTwoFiles() throws {
        let data = try #require(MCPBundle.data(command: command, appVersion: "1.0"))
        let entries = try ZipExtractor.entries(of: data)

        #expect(entries.map(\.name) == ["manifest.json", "server/launch.sh"])
        #expect(entries.allSatisfy { $0.method == 0 && $0.size == $0.compressedSize && !$0.isSymbolicLink })

        let folder = FileManager.default.temporaryDirectory.appending(path: "mcpb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appending(path: "Cumulus.mcpb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: archive)
        let written = try ZipExtractor.extract(archive, to: folder.appending(path: "out"), maximumBytes: 1_000_000)

        #expect(written == 2)
        #expect(try Data(contentsOf: folder.appending(path: "out/manifest.json")) == MCPBundle.manifest(appVersion: "1.0"))
        #expect(try String(contentsOf: folder.appending(path: "out/server/launch.sh"), encoding: .utf8) == MCPBundle.launcher(command: command))
    }

    @Test func theChecksumIsTheOneEveryZipToolExpects() {
        // CRC-32 of "123456789", the check value of the standard.
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipWriter.crc32(Data()) == 0)
    }
}
