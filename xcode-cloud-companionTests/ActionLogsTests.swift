import Compression
import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

/// Builds small ZIP archives by hand, including the ones no honest tool would write.
private enum TestZip {
    struct File {
        var name: String
        var data = Data()
        var deflated = false
        /// The Unix mode recorded for the entry, e.g. `0o120777` for a symbolic link.
        var unixMode: Int?
        /// A size other than the real one, for archives that lie.
        var declaredSize: Int?
        var encrypted = false
    }

    static func make(_ files: [File]) throws -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let payload = file.deflated ? try deflate(file.data) : file.data
            let name = Data(file.name.utf8)
            let offset = archive.count
            let flags = file.encrypted ? 1 : 0
            let method = file.deflated ? 8 : 0
            let size = file.declaredSize ?? file.data.count

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20) + le16(flags) + le16(method) + le16(0) + le16(0))
            archive.append(le32(0) + le32(payload.count) + le32(size))
            archive.append(le16(name.count) + le16(0))
            archive.append(name)
            archive.append(payload)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(file.unixMode == nil ? 20 : (3 << 8 | 20)) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0))
            directory.append(le32(0) + le32(payload.count) + le32(size))
            directory.append(le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0))
            directory.append(le32((file.unixMode ?? 0) << 16) + le32(offset))
            directory.append(name)
        }
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count))
        archive.append(le32(directory.count) + le32(directoryOffset) + le16(0))
        return archive
    }

    static func write(_ files: [File]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "logs-\(UUID().uuidString).zip")
        try make(files).write(to: url)
        return url
    }

    private static func deflate(_ data: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { output.append(chunk) }
        }
        try filter.write(data)
        try filter.finalize()
        return output
    }

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private static func le32(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "unpack-\(UUID().uuidString)")
}

private func files(in folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    let root = folder.standardizedFileURL.path(percentEncoded: false)
    return enumerator.compactMap { $0 as? URL }
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .map { String($0.standardizedFileURL.path(percentEncoded: false).dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        .sorted()
}

struct ZipExtractorTests {
    private let megabyte = 1024 * 1024

    @Test func storedAndDeflatedFilesComeOutAsTheyWentIn() throws {
        let long = Data(String(repeating: "error: build failed\n", count: 5_000).utf8)
        let archive = try TestZip.write([
            .init(name: "logs/"),
            .init(name: "logs/build.log", data: long, deflated: true),
            .init(name: "logs/nested/notes.txt", data: Data("stored".utf8)),
            .init(name: "./summary.txt", data: Data("ok".utf8), deflated: true),
        ])
        let target = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: target) }

        let written = try ZipExtractor.extract(archive, to: target, maximumBytes: megabyte)

        #expect(written == 3)
        #expect(files(in: target) == ["logs/build.log", "logs/nested/notes.txt", "summary.txt"])
        #expect(try Data(contentsOf: target.appending(path: "logs/build.log")) == long)
        #expect(try String(contentsOf: target.appending(path: "logs/nested/notes.txt"), encoding: .utf8) == "stored")
    }

    @Test(arguments: ["../escaped.txt", "logs/../../escaped.txt", "/etc/escaped.txt", "logs/..\\..\\escaped.txt", ".."])
    func anEntryThatClimbsOutRefusesTheWholeArchive(name: String) throws {
        let archive = try TestZip.write([.init(name: "fine.txt", data: Data("fine".utf8)), .init(name: name, data: Data("gotcha".utf8))])
        let parent = temporaryFolder()
        let target = parent.appending(path: "target")
        defer { try? FileManager.default.removeItem(at: parent) }

        #expect(throws: ZipExtractor.Failure.unsafePath(name)) {
            try ZipExtractor.extract(archive, to: target, maximumBytes: megabyte)
        }
        // Judged before anything is written: not even the honest entry is there.
        #expect(files(in: parent) == [])
    }

    @Test func symbolicLinksAreNeverCreated() throws {
        let archive = try TestZip.write([
            .init(name: "build.log", data: Data("log".utf8), unixMode: 0o100644),
            .init(name: "passwd", data: Data("/etc/passwd".utf8), unixMode: 0o120777),
        ])
        let target = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: target) }

        try ZipExtractor.extract(archive, to: target, maximumBytes: megabyte)

        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)) == ["build.log"])
    }

    @Test func anArchiveBiggerThanAllowedOrLyingAboutItsSizeIsRefused() throws {
        let big = Data(repeating: 0x61, count: 200_000)
        let target = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: target) }

        let honest = try TestZip.write([.init(name: "big.log", data: big, deflated: true)])
        #expect(throws: ZipExtractor.Failure.tooLarge) { try ZipExtractor.extract(honest, to: target, maximumBytes: 100_000) }

        let liar = try TestZip.write([.init(name: "bomb.log", data: big, deflated: true, declaredSize: 10)])
        #expect(throws: ZipExtractor.Failure.corrupted) { try ZipExtractor.extract(liar, to: target, maximumBytes: megabyte) }
    }

    @Test func whatIsNotAPlainZipIsRefused() throws {
        let target = temporaryFolder()
        let notZip = FileManager.default.temporaryDirectory.appending(path: "logs-\(UUID().uuidString).zip")
        try Data("<html>Not found</html>".utf8).write(to: notZip)
        #expect(throws: ZipExtractor.Failure.notAnArchive) { try ZipExtractor.extract(notZip, to: target, maximumBytes: megabyte) }

        let encrypted = try TestZip.write([.init(name: "secret.log", data: Data("x".utf8), encrypted: true)])
        #expect(throws: ZipExtractor.Failure.unsupported) { try ZipExtractor.extract(encrypted, to: target, maximumBytes: megabyte) }
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }
}

struct LogCacheTests {
    @Test func unpackedLogsAreFoundAgainAndTheArchiveIsGone() async throws {
        let cache = LogCache(directory: temporaryFolder())
        defer { Task { await cache.deleteAll() } }
        let archive = try TestZip.write([.init(name: "build.log", data: Data("log".utf8))])

        #expect(await cache.folder(actionID: "action-1") == nil)
        let folder = try await cache.unpack(archive, actionID: "action-1", name: "Cumulus #42 – Test: iOS/iPad")

        #expect(folder.lastPathComponent == "Cumulus #42 – Test- iOS-iPad")
        #expect(files(in: folder) == ["build.log"])
        #expect(await cache.folder(actionID: "action-1")?.standardizedFileURL == folder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
        #expect(await cache.folder(actionID: "../x") == nil)
    }

    @Test func aTrappedArchiveLeavesNothingBehind() async throws {
        let directory = temporaryFolder()
        let cache = LogCache(directory: directory)
        defer { Task { await cache.deleteAll() } }
        let archive = try TestZip.write([.init(name: "../../escaped.txt", data: Data("gotcha".utf8))])

        await #expect(throws: ZipExtractor.Failure.self) { try await cache.unpack(archive, actionID: "action-1", name: "Logs") }

        #expect(files(in: directory.deletingLastPathComponent()).filter { $0.contains("escaped") } == [])
        #expect(files(in: directory) == [])
        #expect(await cache.folder(actionID: "action-1") == nil)
    }

    @Test func theOldestLogsGoFirstWhenTheCacheIsFull() async throws {
        let directory = temporaryFolder()
        let cache = LogCache(directory: directory, maximumBytes: 2_500)
        defer { Task { await cache.deleteAll() } }
        let payload = Data(repeating: 0x61, count: 1_000)
        for (index, id) in ["oldest", "middle", "newest"].enumerated() {
            _ = try await cache.unpack(try TestZip.write([.init(name: "build.log", data: payload)]), actionID: id, name: "Logs")
            // Each folder a day younger than the one before, whatever the clock's resolution.
            let date = Date(timeIntervalSince1970: 1_791_000_000 + Double(index) * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.appending(path: id).path(percentEncoded: false))
        }

        cache.prune(keeping: "newest")
        #expect(await cache.folder(actionID: "oldest") == nil)
        #expect(await cache.folder(actionID: "middle") != nil)
        #expect(await cache.folder(actionID: "newest") != nil)

        // One archive larger than the whole cache still opens: it is the one just asked for.
        let huge = LogCache(directory: directory, maximumBytes: 10)
        huge.prune(keeping: "newest")
        #expect(await cache.folder(actionID: "middle") == nil)
        #expect(await cache.folder(actionID: "newest") != nil)
    }
}

@MainActor
struct LogOpenerTests {
    private final class FakeFetcher: ArtifactFetching {
        private let results: Mutex<[ArtifactFetchResult]>
        let addresses = Mutex<[URL]>([])

        init(_ results: [ArtifactFetchResult]) {
            self.results = Mutex(results)
        }

        func fetch(_ address: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> ArtifactFetchResult {
            addresses.withLock { $0.append(address) }
            progress(0.5)
            return results.withLock { $0.isEmpty ? .status(500) : $0.removeFirst() }
        }
    }

    private final class Revealed: Sendable {
        let folders = Mutex<[URL]>([])
    }

    private let cache = LogCache(directory: temporaryFolder())
    private let revealed = Revealed()

    private func action(_ progress: CIExecutionProgress = .complete) -> CIBuildAction {
        CIBuildAction(
            id: "action-1", buildRunID: "run-1", name: "Test - iOS", actionType: .test, startedDate: nil, finishedDate: nil,
            executionProgress: progress, completionStatus: progress == .complete ? .failed : nil, isRequiredToPass: true
        )
    }

    private func run(_ progress: CIExecutionProgress = .complete) -> CIBuildRun {
        CIBuildRun(
            id: "run-1", productID: "p1", number: 42, createdDate: nil, startedDate: nil, finishedDate: nil, executionProgress: progress,
            completionStatus: progress == .complete ? .failed : nil, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func opener(_ fetcher: FakeFetcher, artifactBody: Data? = nil, listBody: Data? = nil) -> (LogOpener, MockTransport) {
        let transport = MockTransport { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/artifacts") {
                return MockTransport.Reply(body: listBody ?? ((try? Fixture.data("ciArtifacts-sample")) ?? Data()))
            }
            return MockTransport.Reply(body: artifactBody ?? ((try? Fixture.data("ciArtifact-sample")) ?? Data()))
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let revealed = revealed
        return (LogOpener(client: { client }, fetcher: fetcher, cache: cache, reveal: { url in revealed.folders.withLock { $0.append(url) } }), transport)
    }

    private func logArchive() throws -> URL {
        try TestZip.write([.init(name: "build.log", data: Data("error: nope".utf8), deflated: true)])
    }

    @Test func theLogsAreDownloadedUnpackedAndOpenedThenReopenedWithoutAnyCall() async throws {
        defer { Task { [cache] in await cache.deleteAll() } }
        let fetcher = FakeFetcher([.file(try logArchive())])
        let (opener, transport) = opener(fetcher)

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Cumulus #42 – Test - iOS")

        let folder = try #require(revealed.folders.withLock { $0.first })
        #expect(opener.state(of: "action-1") == .idle)
        #expect(folder.lastPathComponent == "Cumulus #42 – Test - iOS")
        #expect(try String(contentsOf: folder.appending(path: "build.log"), encoding: .utf8) == "error: nope")
        #expect(fetcher.addresses.withLock { $0.map(\.host) } == ["example.icloud-content.com"])
        // The action's files, then the fresh address of the log archive.
        #expect(await transport.requests.compactMap { $0.url?.path() } == ["/v1/ciBuildActions/action-1/artifacts", "/v1/ciArtifacts/art-1"])
        // No token goes to the download host: the fetcher only ever sees the signed address.
        #expect(fetcher.addresses.withLock { $0.count } == 1)

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Cumulus #42 – Test - iOS")
        #expect(revealed.folders.withLock { $0.count } == 2)
        #expect(await transport.requests.count == 2)
        #expect(fetcher.addresses.withLock { $0.count } == 1)
    }

    @Test func aRunningBuildsLogsAreFetchedAgain() async throws {
        defer { Task { [cache] in await cache.deleteAll() } }
        let fetcher = FakeFetcher([.file(try logArchive()), .file(try logArchive())])
        let (opener, _) = opener(fetcher)
        let known = [CIArtifact(id: "art-1", buildActionID: "action-1", fileType: "LOG_BUNDLE", fileName: "Logs.zip", fileSize: 10, downloadURL: nil)]

        await opener.open(action(), run: run(.running), knownArtifacts: known, title: "Logs")
        await opener.open(action(), run: run(.running), knownArtifacts: known, title: "Logs")

        #expect(fetcher.addresses.withLock { $0.count } == 2)
        #expect(revealed.folders.withLock { $0.count } == 2)
    }

    @Test func anActionWithoutALogArchiveLosesItsButton() async {
        let (opener, transport) = opener(FakeFetcher([]), listBody: Data(#"{"data": [{"type": "ciArtifacts", "id": "a", "attributes": {"fileType": "RESULT_BUNDLE"}}]}"#.utf8))
        #expect(opener.offersLogs(for: action(), knownArtifacts: nil))
        #expect(!opener.offersLogs(for: action(.running), knownArtifacts: nil))

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Logs")

        #expect(opener.state(of: "action-1") == .idle)
        #expect(!opener.offersLogs(for: action(), knownArtifacts: nil))
        #expect(revealed.folders.withLock { $0.isEmpty })
        #expect(await transport.requests.count == 1)

        let (fresh, _) = self.opener(FakeFetcher([]))
        let results = [CIArtifact(id: "a", buildActionID: "action-1", fileType: "RESULT_BUNDLE", fileName: nil, fileSize: nil, downloadURL: nil)]
        #expect(!fresh.offersLogs(for: action(), knownArtifacts: results))
        #expect(!fresh.offersLogs(for: action(), knownArtifacts: []))
    }

    @Test func anUntrustedHostDownloadsNothing() async {
        let body = Data(#"{"data":{"type":"ciArtifacts","id":"art-1","attributes":{"fileType":"LOG_BUNDLE","downloadUrl":"https://evil.example.com/logs.zip"}}}"#.utf8)
        let fetcher = FakeFetcher([])
        let (opener, _) = opener(fetcher, artifactBody: body)

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Logs")

        #expect(opener.state(of: "action-1") == .failed("Apple gave an address this app doesn’t trust, so nothing was downloaded."))
        #expect(fetcher.addresses.withLock { $0.isEmpty })
        #expect(revealed.folders.withLock { $0.isEmpty })
    }

    @Test func aTrappedArchiveIsReportedAndNothingIsOpened() async throws {
        defer { Task { [cache] in await cache.deleteAll() } }
        let trapped = try TestZip.write([.init(name: "../../../escaped.txt", data: Data("gotcha".utf8))])
        let (opener, _) = opener(FakeFetcher([.file(trapped)]))

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Logs")

        #expect(opener.state(of: "action-1") == .failed("The log archive can’t be unpacked safely. Save it from the Artifacts tab instead."))
        #expect(revealed.folders.withLock { $0.isEmpty })
        #expect(await cache.folder(actionID: "action-1") == nil)
    }

    @Test func aLinkRefusedTwiceReportsTheCode() async {
        let fetcher = FakeFetcher([.status(403), .status(403)])
        let (opener, transport) = opener(fetcher)

        await opener.open(action(), run: run(), knownArtifacts: nil, title: "Logs")

        #expect(opener.state(of: "action-1") == .failed("The link expired or is invalid (HTTP 403)."))
        #expect(fetcher.addresses.withLock { $0.count } == 2)
        #expect(await transport.requests.count == 3)
    }
}
