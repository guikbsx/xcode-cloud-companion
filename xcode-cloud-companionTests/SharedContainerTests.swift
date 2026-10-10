import Foundation
import Testing
@testable import XcodeCloudCompanion

struct SharedContainerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theGroupContainerIsUsedWhenItCanBeWritten() throws {
        let group = try temporaryDirectory()
        let fallback = try temporaryDirectory()

        let resolved = SharedContainer.resolve(groupContainer: group, fallback: fallback)

        #expect(resolved.path(percentEncoded: false).hasPrefix(group.path(percentEncoded: false)))
        #expect(resolved.path(percentEncoded: false).hasSuffix("Library/Application Support/"))
        #expect(FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)))
    }

    @Test func withoutAGroupContainerTheOwnFolderIsKept() throws {
        let fallback = try temporaryDirectory()

        #expect(SharedContainer.resolve(groupContainer: nil, fallback: fallback) == fallback)
    }

    @Test func aGroupContainerThatRefusesWritesFallsBack() throws {
        let fallback = try temporaryDirectory()
        // A file where the container should be: no folder can be created under it.
        let blocked = try temporaryDirectory().appending(path: "not-a-folder")
        try Data().write(to: blocked)

        #expect(SharedContainer.resolve(groupContainer: blocked, fallback: fallback) == fallback)
    }

    @Test func theMigrationMovesEveryCacheOnce() async throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory().appending(path: "Library/Application Support")
        try Data("cache".utf8).write(to: source.appending(path: "BuildCache.json"))
        try Data("ledger".utf8).write(to: source.appending(path: "UsageLedger.json"))
        try FileManager.default.createDirectory(at: source.appending(path: "BuildDetails"), withIntermediateDirectories: true)
        try Data("run".utf8).write(to: source.appending(path: "BuildDetails/run-1.json"))
        try Data("other".utf8).write(to: source.appending(path: "Unrelated.json"))

        await CacheMigration(source: source, destination: destination).run()

        #expect(try String(contentsOf: destination.appending(path: "BuildCache.json"), encoding: .utf8) == "cache")
        #expect(try String(contentsOf: destination.appending(path: "UsageLedger.json"), encoding: .utf8) == "ledger")
        #expect(try String(contentsOf: destination.appending(path: "BuildDetails/run-1.json"), encoding: .utf8) == "run")
        #expect(!FileManager.default.fileExists(atPath: source.appending(path: "BuildCache.json").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: source.appending(path: "BuildDetails").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "Unrelated.json").path(percentEncoded: false)))
    }

    @Test func whatIsAlreadyAtTheDestinationWins() async throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory()
        try Data("old".utf8).write(to: source.appending(path: "BuildCache.json"))
        try Data("new".utf8).write(to: destination.appending(path: "BuildCache.json"))
        try FileManager.default.createDirectory(at: source.appending(path: "BuildDetails"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appending(path: "BuildDetails"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appending(path: "BuildDetails/run-1.json"))
        try Data("new".utf8).write(to: destination.appending(path: "BuildDetails/run-1.json"))
        try Data("only-old".utf8).write(to: source.appending(path: "BuildDetails/run-2.json"))

        await CacheMigration(source: source, destination: destination).run()

        #expect(try String(contentsOf: destination.appending(path: "BuildCache.json"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: destination.appending(path: "BuildDetails/run-1.json"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: destination.appending(path: "BuildDetails/run-2.json"), encoding: .utf8) == "only-old")
        // Nothing is thrown away: the copies that lost stay where they were.
        #expect(try String(contentsOf: source.appending(path: "BuildCache.json"), encoding: .utf8) == "old")
    }

    @Test func aMigrationOntoItselfChangesNothing() async throws {
        let directory = try temporaryDirectory()
        try Data("cache".utf8).write(to: directory.appending(path: "BuildCache.json"))

        await CacheMigration(source: directory, destination: directory).run()

        #expect(try String(contentsOf: directory.appending(path: "BuildCache.json"), encoding: .utf8) == "cache")
    }

    @Test func thePlanIsCopiedForTheCommandAndRemovedWithIt() async throws {
        let store = SharedPlanStore(fileURL: try temporaryDirectory().appending(path: "UsagePlan.json"))
        let plan = UsagePlan(hours: 100, resetAnchor: Date(timeIntervalSince1970: 1_780_000_000))

        await store.save(plan)
        #expect(await store.load() == plan)

        await store.save(nil)
        #expect(await store.load() == nil)
    }
}
