import Foundation

/// A Claude Desktop extension (`.mcpb`): a zip holding a manifest and a launcher for this app's `cumulus` command.
/// The launcher runs the command where the app is, so the extension follows the app's updates; it is exported again
/// only if the app moves.
nonisolated enum MCPBundle {
    static let fileName = "Cumulus.mcpb"
    static let launcherPath = "server/launch.sh"

    static func data(command: URL, appVersion: String) -> Data? {
        guard let manifest = manifest(appVersion: appVersion) else { return nil }
        return ZipWriter.archive([
            ZipWriter.File(name: "manifest.json", data: manifest),
            ZipWriter.File(name: launcherPath, data: Data(launcher(command: command).utf8), isExecutable: true),
        ])
    }

    /// Run through `/bin/sh`, so that nothing depends on the archive keeping the script executable.
    static func launcher(command: URL) -> String {
        let path = command.path(percentEncoded: false)
        return "#!/bin/sh\nexec '" + path.replacing("'", with: "'\\''") + "' mcp\n"
    }

    static func manifest(appVersion: String) -> Data? {
        let manifest: JSONValue = [
            "manifest_version": "0.3",
            "name": "cumulus",
            "display_name": "Cumulus",
            "version": .string(semanticVersion(appVersion)),
            "description": "Xcode Cloud builds and compute usage, read from the Cumulus app on this Mac.",
            "author": ["name": "Cumulus"],
            "server": [
                "type": "binary",
                "entry_point": .string(launcherPath),
                "mcp_config": ["command": "/bin/sh", "args": [.string("${__dirname}/" + launcherPath)]],
            ],
            "tools": .array(MCPTools.all.map { ["name": .string($0.name), "description": .string($0.description)] }),
            "compatibility": ["platforms": ["darwin"]],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(manifest)
    }

    /// The manifest wants three numbers; the app's version has two.
    static func semanticVersion(_ version: String) -> String {
        var parts = version.split(separator: ".").prefix(3).map { String($0.prefix { $0.isNumber }) }.map { $0.isEmpty ? "0" : $0 }
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }
}

/// Writes a zip of stored entries: all an extension of two small text files needs.
nonisolated enum ZipWriter {
    struct File: Sendable {
        var name: String
        var data: Data
        var isExecutable = false
    }

    static func archive(_ files: [File]) -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let checksum = crc32(file.data)
            let offset = archive.count
            // Local header: stored, no flags, dated 1980-01-01 so that the same files give the same archive.
            archive.append(uint32: 0x0403_4B50)
            archive.append(uint16: 20)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0x0021)
            archive.append(uint32: checksum)
            archive.append(uint32: UInt32(file.data.count))
            archive.append(uint32: UInt32(file.data.count))
            archive.append(uint16: UInt16(name.count))
            archive.append(uint16: 0)
            archive.append(name)
            archive.append(file.data)

            // Made on Unix (3), so that the mode in the external attributes is read.
            directory.append(uint32: 0x0201_4B50)
            directory.append(uint16: 3 << 8 | 20)
            directory.append(uint16: 20)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0x0021)
            directory.append(uint32: checksum)
            directory.append(uint32: UInt32(file.data.count))
            directory.append(uint32: UInt32(file.data.count))
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: UInt32(file.isExecutable ? 0o100755 : 0o100644) << 16)
            directory.append(uint32: UInt32(offset))
            directory.append(name)
        }
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(uint32: 0x0605_4B50)
        archive.append(uint16: 0)
        archive.append(uint16: 0)
        archive.append(uint16: UInt16(files.count))
        archive.append(uint16: UInt16(files.count))
        archive.append(uint32: UInt32(directory.count))
        archive.append(uint32: UInt32(directoryOffset))
        archive.append(uint16: 0)
        return archive
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

private nonisolated extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        append(uint16: UInt16(value & 0xFFFF))
        append(uint16: UInt16(value >> 16))
    }
}
