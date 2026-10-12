import Foundation
import Testing
@testable import XcodeCloudCompanion

struct RepositoryFileLocatorTests {
    @Test func theBuildMachinesPathBecomesThePathInsideTheRepository() {
        #expect(RepositoryFileLocator.relativePath(of: "/Volumes/workspace/repository/Sources/App/Usage.swift") == "Sources/App/Usage.swift")
        #expect(RepositoryFileLocator.relativePath(of: "Sources/App/Usage.swift") == "Sources/App/Usage.swift")
        #expect(RepositoryFileLocator.relativePath(of: "/Volumes/workspace/repository/") == nil)
        #expect(RepositoryFileLocator.relativePath(of: "/Users/me/Elsewhere/File.swift") == nil, "an absolute path outside the checkout")
        #expect(RepositoryFileLocator.relativePath(of: "/Volumes/workspace/repository/../secrets") == nil)
        #expect(RepositoryFileLocator.relativePath(of: "a/../../b") == nil)
    }

    @Test func theLocalFileStaysInsideTheClone() {
        let root = URL(filePath: "/Users/me/Developer/cumulus", directoryHint: .isDirectory)

        #expect(RepositoryFileLocator.localURL(for: "/Volumes/workspace/repository/Sources/A.swift", in: root)?.path() == "/Users/me/Developer/cumulus/Sources/A.swift")
        #expect(RepositoryFileLocator.localURL(for: "/etc/passwd", in: root) == nil)
        #expect(RepositoryFileLocator.localURL(for: "../cumulus-other/A.swift", in: root) == nil)
    }
}

@MainActor
struct LocalRepositoriesTests {
    @Test func aChosenFolderIsKeptPerProductAndSurvivesARestart() throws {
        let suite = "LocalRepositoriesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appending(path: "A.swift"))

        let first = LocalRepositories(accountID: "acc", defaults: defaults)
        #expect(first.set(folder, for: "cumulus"))
        #expect(first.root(for: "cumulus")?.standardizedFileURL == folder.standardizedFileURL)
        #expect(first.root(for: "other") == nil)

        let again = LocalRepositories(accountID: "acc", defaults: defaults)
        #expect(again.root(for: "cumulus")?.standardizedFileURL == folder.standardizedFileURL)
        #expect(again.withAccess(to: "cumulus") { root in FileManager.default.fileExists(atPath: root.appending(path: "A.swift").path()) } == true)
        #expect(LocalRepositories(accountID: "someone-else", defaults: defaults).root(for: "cumulus") == nil, "another account's preference")

        again.forget("cumulus")
        #expect(again.root(for: "cumulus") == nil && LocalRepositories(accountID: "acc", defaults: defaults).root(for: "cumulus") == nil)
        #expect(AccountDefaults.names.contains(AccountDefaults.localRepositories), "removed with the account")
    }
}
