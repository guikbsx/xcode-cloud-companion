import Compression
import Foundation

/// Unpacks a ZIP archive Apple served, never writing outside the target folder: an entry that climbs out (`..`, an absolute
/// path) refuses the whole archive, and symbolic links are never created.
nonisolated enum ZipExtractor {
    enum Failure: Error, Equatable {
        case notAnArchive
        /// Encrypted, split, ZIP64 or an unknown compression: nothing a log archive should be.
        case unsupported
        case unsafePath(String)
        case tooLarge
        case corrupted
    }

    struct Entry: Equatable, Sendable {
        let name: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let isSymbolicLink: Bool

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    static let maximumEntries = 50_000

    /// Returns how many files were written. `target` is created; on failure, what was already written is left for the caller to remove.
    @discardableResult
    static func extract(_ archive: URL, to target: URL, maximumBytes: Int) throws -> Int {
        guard let data = try? Data(contentsOf: archive, options: .mappedIfSafe) else { throw Failure.notAnArchive }
        let entries = try entries(of: data)
        guard entries.reduce(0, { $0 + $1.size }) <= maximumBytes else { throw Failure.tooLarge }

        // Every path is judged before the first byte is written.
        let planned = try entries.map { entry in (entry, try destination(of: entry, in: target)) }
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        var written = 0
        for (entry, destination) in planned where !entry.isSymbolicLink {
            if entry.isDirectory {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(entry, from: data, to: destination)
            written += 1
        }
        return written
    }

    static func entries(of data: Data) throws(Failure) -> [Entry] {
        guard let end = endOfCentralDirectory(in: data),
              let count = data.uint16(at: end + 10), let onThisDisk = data.uint16(at: end + 8),
              let directorySize = data.uint32(at: end + 12), let directoryOffset = data.uint32(at: end + 16)
        else { throw .notAnArchive }
        guard count == onThisDisk, count != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else { throw .unsupported }
        guard count <= maximumEntries, directoryOffset + directorySize <= end else { throw .corrupted }

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard data.uint32(at: offset) == 0x0201_4B50,
                  let madeBy = data.uint16(at: offset + 4), let flags = data.uint16(at: offset + 8), let method = data.uint16(at: offset + 10),
                  let compressedSize = data.uint32(at: offset + 20), let size = data.uint32(at: offset + 24),
                  let nameLength = data.uint16(at: offset + 28), let extraLength = data.uint16(at: offset + 30),
                  let commentLength = data.uint16(at: offset + 32), let attributes = data.uint32(at: offset + 38),
                  let localHeaderOffset = data.uint32(at: offset + 42), offset + 46 + nameLength <= data.count
            else { throw .corrupted }
            guard flags & 1 == 0, method == 0 || method == 8, compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw .unsupported }
            let nameStart = data.startIndex + offset + 46
            guard let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8) else { throw .corrupted }
            // Unix archives keep the file mode in the high half of the external attributes: 0o120000 is a symbolic link.
            let isUnix = madeBy >> 8 == 3
            entries.append(Entry(
                name: name, method: method, compressedSize: compressedSize, size: size, localHeaderOffset: localHeaderOffset,
                isSymbolicLink: isUnix && (attributes >> 16) & 0o170000 == 0o120000
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Where an entry lands, or the refusal of a name that would leave `target`.
    static func destination(of entry: Entry, in target: URL) throws(Failure) -> URL {
        let name = entry.name
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0") else { throw .unsafePath(name) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(where: { $0.split(separator: "\\", omittingEmptySubsequences: false).contains("..") }) else {
            throw .unsafePath(name)
        }
        let destination = parts.reduce(target) { $0.appending(path: String($1)) }.standardizedFileURL
        let root = target.standardizedFileURL.path(percentEncoded: false)
        guard destination.path(percentEncoded: false).hasPrefix(root.hasSuffix("/") ? root : root + "/") else { throw .unsafePath(name) }
        return destination
    }

    // MARK: - Private

    private static func write(_ entry: Entry, from data: Data, to destination: URL) throws {
        guard data.uint32(at: entry.localHeaderOffset) == 0x0403_4B50,
              let nameLength = data.uint16(at: entry.localHeaderOffset + 26), let extraLength = data.uint16(at: entry.localHeaderOffset + 28)
        else { throw Failure.corrupted }
        let start = data.startIndex + entry.localHeaderOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.endIndex else { throw Failure.corrupted }
        let payload = data[start..<start + entry.compressedSize]

        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else { throw Failure.corrupted }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if entry.method == 0 {
            guard payload.count == entry.size else { throw Failure.corrupted }
            try handle.write(contentsOf: payload)
            return
        }
        var position = payload.startIndex
        let filter = try InputFilter(.decompress, using: .zlib) { (length: Int) -> Data? in
            guard position < payload.endIndex else { return nil }
            let chunk = payload[position..<min(position + length, payload.endIndex)]
            position = chunk.endIndex
            return chunk
        }
        var total = 0
        while let chunk = try filter.readData(ofLength: 1 << 16), !chunk.isEmpty {
            total += chunk.count
            // An entry that inflates past the size it declared is lying about it.
            guard total <= entry.size else { throw Failure.corrupted }
            try handle.write(contentsOf: chunk)
        }
        guard total == entry.size else { throw Failure.corrupted }
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var offset = data.count - 22
        while offset >= lowest {
            if data.uint32(at: offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }
}

private nonisolated extension Data {
    /// Little-endian, as everything in a ZIP; nil past the end.
    func uint16(at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return Int(self[base]) | Int(self[base + 1]) << 8
    }

    func uint32(at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return Int(self[base]) | Int(self[base + 1]) << 8 | Int(self[base + 2]) << 16 | Int(self[base + 3]) << 24
    }
}
