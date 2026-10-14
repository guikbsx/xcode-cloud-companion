import Foundation
import Testing
@testable import XcodeCloudCompanion

private func scan(_ name: String, rules: LogErrorScanner.Rules) throws -> LogErrorScanner.Result {
    var scanner = LogErrorScanner(rules: rules)
    for line in try Fixture.logLines(name) { scanner.feed(line) }
    return scanner.finish()
}

private func scan(_ lines: [String], rules: LogErrorScanner.Rules) -> LogErrorScanner.Result {
    var scanner = LogErrorScanner(rules: rules)
    for line in lines { scanner.feed(line) }
    return scanner.finish()
}

private func stamped(_ text: String) -> String {
    "2026-10-08T07:58:26.488826248Z\t" + text
}

struct LogLineCleanerTests {
    @Test func theTimestampGoesWhateverTheNumberOfDecimals() {
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.488826248Z\terror: x") == "error: x")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.4888Z\terror: x") == "error: x")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26Z\terror: x") == "error: x")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.488826248Z\t") == "")
    }

    @Test func whatIsNotATimestampStays() {
        #expect(LogLineCleaner.clean("error: x") == "error: x")
        #expect(LogLineCleaner.clean("2026-10-08 08:42:04 +0000 [MT] hello") == "2026-10-08 08:42:04 +0000 [MT] hello")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.4888268481Z\tx") == "2026-10-08T07:58:26.4888268481Z\tx")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.Z\tx") == "2026-10-08T07:58:26.Z\tx")
        #expect(LogLineCleaner.clean("2026-10-08T07:58:26.488826248Z x") == "2026-10-08T07:58:26.488826248Z x")
        #expect(LogLineCleaner.clean("") == "")
    }

    @Test func colourCodesGo() {
        #expect(LogLineCleaner.clean(stamped("\u{1B}[0;32m✓\u{1B}[0m ok \u{1B}[1mbold\u{1B}[0m")) == "✓ ok bold")
        #expect(LogLineCleaner.clean("\u{1B}[31merror: x") == "error: x")
    }

    @Test func aLongLineIsCutForDisplayAndSaysSo() {
        let long = String(repeating: "a", count: 500)
        let shown = LogLineCleaner.shortened(long)
        #expect(shown.count == LogLineCleaner.displayLimit + 1)
        #expect(shown.hasSuffix("…"))
        #expect(LogLineCleaner.shortened(String(repeating: "b", count: 300)) == String(repeating: "b", count: 300))
    }
}

struct LogErrorScannerTests {
    @Test func compileErrorsAreFoundOnceEachEvenWhenPrintedForTwoArchitectures() throws {
        let result = try scan("compile-error-archive", rules: .build)

        #expect(result.totalLines == 78)
        #expect(result.findings.map(\.lineNumber) == [12, 20, 28])
        #expect(result.findings.allSatisfy { $0.family == .compile })
        let first = try #require(result.findings.first)
        #expect(first.location == LogFinding.Location(fileName: "PanelFold.swift", line: 72))
        #expect(first.line.text == "/Volumes/workspace/repository/acmeapp/Views/Components/Row/PanelFold.swift:72:22: error: value of type 'GeometryProxy' has no member 'reservedRegions'")
        #expect(first.before.map(\.number) == [9, 10, 11])
        #expect(first.after.map(\.number) == [13, 14, 15])
        #expect(first.after.first?.text == "70 |     private nonisolated static func fold(in proxy: GeometryProxy) -> PanelFold? {")
        #expect(result.findings.map(\.location?.fileName) == ["PanelFold.swift", "PanelHinge.swift", "CameraPreview.swift"])
    }

    @Test func aFailedSwiftTestingTestIsFoundWithItsDetail() throws {
        let result = try scan("swift-testing-failure", rules: .build)

        let finding = try #require(result.findings.first)
        #expect(result.findings.count == 1)
        #expect(finding.family == .testIssue)
        #expect(finding.location == LogFinding.Location(fileName: "ScoreStoreTests.swift", line: 49))
        #expect(finding.line.text.hasPrefix("✘ Test \"The sample data set yields a usable score\" recorded an issue at ScoreStoreTests.swift:49:25"))
        #expect(finding.after.first?.text == "↳ The sample data does not allow a score to be shown.")
        // The summaries, and the marker at the end of the file, say that something failed, never what.
        #expect(finding.after.count == 3)
        #expect(result.totalLines == 53)
    }

    @Test func aBareXcodebuildErrorIsFound() throws {
        let scheme = try scan("scheme-missing", rules: .bare)
        #expect(scheme.findings.map(\.lineNumber) == [5])
        #expect(scheme.totalLines == 5)
        #expect(scheme.findings.first?.family == .xcodebuild)
        #expect(scheme.findings.first?.line.text.hasPrefix("xcodebuild: error: The project named") == true)
        #expect(scheme.findings.first?.before.count == 3)
        #expect(scheme.findings.first?.after.isEmpty == true)

        let export = try scan("export-failed", rules: .bare)
        #expect(export.findings.map(\.lineNumber) == [22, 25])
        #expect(export.findings.first?.line.text == "error: exportArchive Automatic signing cannot register bundle identifier \"devplaceholder.ABCDE12345.sample-app\".")
        // The continuation line is the one after it; the marker at the end is not a finding.
        #expect(export.findings.first?.after.first?.text.hasPrefix("  Automatic signing cannot register") == true)
        #expect(export.findings.contains { $0.line.text.contains("EXPORT FAILED") } == false)
    }

    @Test func aLogWithoutAnErrorLineGivesNothing() throws {
        for name in ["success-noise", "no-cause-in-bundle", "script-decoy"] {
            for rules in [LogErrorScanner.Rules.build, .bare] {
                #expect(try scan(name, rules: rules).findings.isEmpty, "\(name)")
            }
        }
    }

    @Test func aScriptsFailedTestRunIsNotTheCause() throws {
        let decoy = try Fixture.logLines("script-decoy")
        #expect(decoy.contains { $0.contains("✘ Test run with 48 tests") })
        #expect(scan(decoy, rules: .build).findings.isEmpty)
    }

    @Test func theWordErrorAloneIsNeverEnough() {
        let noise = [
            "SwiftCompile normal arm64 Compiling PreviewError.swift, ErrorMessage.swift",
            "Compiling Foo+Error.swift",
            "DVTServices: Failed to create Capabilities directory in user data at \"/x\": Error Domain=NSCocoaErrorDomain Code=4",
            "[CloudKit] Error Domain=NSCocoaErrorDomain Code=134400 \"Unable to initialize without an iCloud account\"",
            "✘ Test run with 48 tests in 5 suites failed after 0.008 seconds with 15 issues.",
            "✘ Test \"x\" failed after 0.008 seconds with 1 issue.",
            "✘ Suite \"y\" failed after 0.024 seconds with 1 issue.",
            "    /Volumes/workspace/repository/App/File.swift:1:2: error: indented, so a quotation",
            "   |                      `- error: value of type 'GeometryProxy' has no member",
            "The following build commands failed:",
            "** ARCHIVE FAILED **",
            "App Store Connect request for store configuration failed",
            "xcodebuild: warning: error: not at the start",
            "see /Volumes/workspace/repository/App/File.swift:1:2: error: in the middle of a line",
            "/Volumes/workspace/repository/App/File.swift: error: no line and column",
            "relative/File.swift:1:2: error: relative paths are not the compiler's",
            "Test \"x\" recorded an issue at File.swift:1:2: without the cross",
            "✘ Test x recorded an issue but names no place",
        ].map(stamped)

        #expect(scan(noise, rules: .build).findings.isEmpty)
        #expect(scan(noise, rules: .bare).findings.isEmpty)
    }

    @Test func eachFamilyHasItsOwnRules() {
        let lines = [
            stamped("/Volumes/workspace/repository/App/File.swift:7:3: error: nope"),
            stamped("✘ Test \"t\" recorded an issue at FileTests.swift:9:1: Expectation failed"),
            stamped("error: exportArchive nope"),
        ]
        #expect(scan(lines, rules: .build).findings.map(\.family) == [.compile, .testIssue])
        #expect(scan(lines, rules: .bare).findings.map(\.family) == [.xcodebuild])
    }

    @Test func swiftTestingNamesWithoutQuotesAndWithArgumentsAreFound() {
        let lines = [
            stamped("✘ Test example() recorded an issue at ExampleTests.swift:12:5: Expectation failed: (a → 1) == (b → 2)"),
            stamped("✘ Test scores(value:) recorded an issue with 1 argument value → \"at 5: x\" at ScoreTests.swift:30:9: Expectation failed"),
        ]
        let found = scan(lines, rules: .build).findings

        #expect(found.map(\.location) == [LogFinding.Location(fileName: "ExampleTests.swift", line: 12), LogFinding.Location(fileName: "ScoreTests.swift", line: 30)])
    }

    @Test func twentyErrorsAtMostAreKept() {
        let lines = (1...30).map { stamped("/Volumes/workspace/repository/App/File\($0).swift:\($0):1: error: problem \($0)") }
        let result = scan(lines, rules: .build)

        #expect(result.findings.count == LogErrorScanner.maximumFindings)
        #expect(result.findings.map(\.lineNumber) == Array(1...20))
        #expect(result.totalLines == 30)
        // The last one kept still gets its lines after it.
        #expect(result.findings.last?.after.map(\.number) == [21, 22, 23])
    }

    @Test func theLinesAroundAnErrorAtTheEdgesOfTheFile() {
        let first = scan(["error: first", "after one", "after two", "after three", "after four"].map(stamped), rules: .bare)
        #expect(first.findings.first?.before.isEmpty == true)
        #expect(first.findings.first?.after.map(\.text) == ["after one", "after two", "after three"])

        let last = scan(["a", "b", "c", "d", "error: last"].map(stamped), rules: .bare)
        #expect(last.findings.first?.before.map(\.text) == ["b", "c", "d"])
        #expect(last.findings.first?.after.isEmpty == true)
        #expect(last.totalLines == 5)

        #expect(scan([], rules: .build) == LogErrorScanner.Result(totalLines: 0, findings: []))
    }

    @Test func twoErrorsCloseTogetherEachKeepTheirOwnLines() {
        let result = scan(["x", "error: one", "y", "error: two", "z"].map(stamped), rules: .bare)

        #expect(result.findings.map(\.lineNumber) == [2, 4])
        #expect(result.findings[0].after.map(\.text) == ["y", "error: two", "z"])
        #expect(result.findings[1].before.map(\.text) == ["x", "error: one", "y"])
    }

    @Test func aLongLineIsShortenedAndColourCodesAreGone() {
        let long = "/Volumes/workspace/repository/App/File.swift:7:3: error: " + String(repeating: "x", count: 400)
        let result = scan([stamped(long), stamped("\u{1B}[0;31mred\u{1B}[0m")], rules: .build)

        let finding = result.findings[0]
        #expect(finding.line.text.count == LogLineCleaner.displayLimit + 1)
        #expect(finding.after.first?.text == "red")
    }
}

struct LogExcerptSearchTests {
    private func logFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "excerpt-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func text(of name: String) throws -> String {
        try Fixture.logLines(name).joined(separator: "\n") + "\n"
    }

    @Test func theErrorIsFoundInTheBuildLogOfABundle() async throws {
        let bundle = "Acme Build 3 Logs for Archive"
        let folder = try logFolder([
            "\(bundle)/xcodebuild-archive.log": try text(of: "compile-error-archive"),
            "\(bundle)/resolve_package_dependencies.log": try text(of: "success-noise"),
            "\(bundle)/ci_post_clone.log": try text(of: "script-decoy"),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let outcome = await LogExcerptSearch.search(in: folder, hints: [])

        guard case .found(let excerpt) = outcome else { Issue.record("nothing found"); return }
        #expect(excerpt.fileName == "xcodebuild-archive.log")
        #expect(excerpt.totalLines == 78)
        #expect(excerpt.findings.map(\.lineNumber) == [12, 20, 28])
    }

    @Test func theTestLogOfADeviceHoldsTheFailedTest() async throws {
        let folder = try logFolder(["Acme Build 9 Logs for Tests test-without-building on iPhone 16/xcodebuild-test-without-building.log": try text(of: "swift-testing-failure")])
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .found(let excerpt) = await LogExcerptSearch.search(in: folder, hints: []) else { Issue.record("nothing found"); return }

        #expect(excerpt.fileName == "xcodebuild-test-without-building.log")
        #expect(excerpt.findings.first?.family == .testIssue)
    }

    @Test func aRefusedExportIsFoundInTheDestinationThatFailed() async throws {
        let folder = try logFolder([
            "Acme/xcodebuild-archive.log": try text(of: "no-cause-in-bundle"),
            "Acme/ad-hoc-export-archive-logs/xcodebuild-export-archive.log": try text(of: "no-cause-in-bundle"),
            "Acme/app-store-export-archive-logs/xcodebuild-export-archive.log": try text(of: "export-failed"),
            "Acme/app-store-export-archive-logs/Acme_2026.xcdistributionlogs/IDEDistribution.verbose.log": "error: Step failed: noise\n",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .found(let excerpt) = await LogExcerptSearch.search(in: folder, hints: []) else { Issue.record("nothing found"); return }

        #expect(excerpt.fileName == "app-store-export-archive-logs/xcodebuild-export-archive.log")
        #expect(excerpt.findings.map(\.lineNumber) == [22, 25])
    }

    @Test func aMissingSchemeIsFoundInThePackageResolution() async throws {
        let folder = try logFolder(["Acme/resolve_package_dependencies.log": try text(of: "scheme-missing")])
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .found(let excerpt) = await LogExcerptSearch.search(in: folder, hints: []) else { Issue.record("nothing found"); return }

        #expect(excerpt.fileName == "resolve_package_dependencies.log")
        #expect(excerpt.findings.first?.family == .xcodebuild)
    }

    @Test func filesThatProveNothingAreNotRead() async throws {
        let folder = try logFolder([
            "Acme/ci_post_clone.log": "error: from my script\n/Volumes/workspace/repository/A.swift:1:1: error: in a script\n",
            "Acme/x.xcdistributionlogs/IDEDistribution.verbose.log": "error: Step failed\n",
            "Acme/notes.txt": "error: not a log\n",
            "Acme/xcodebuild-archive.log": try text(of: "success-noise"),
            "Acme/app-store-export-archive-logs/xcodebuild-export-archive.log": try text(of: "no-cause-in-bundle"),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(await LogExcerptSearch.search(in: folder, hints: []) == .nothing)
        #expect(LogExcerptSearch.candidates(in: folder).map(\.displayName) == ["xcodebuild-archive.log", "app-store-export-archive-logs/xcodebuild-export-archive.log"])
    }

    @Test func anEmptyOrMissingFolderGivesNothing() async throws {
        #expect(await LogExcerptSearch.search(in: FileManager.default.temporaryDirectory.appending(path: "nowhere-\(UUID().uuidString)"), hints: []) == .nothing)
        let folder = try logFolder(["Acme/xcodebuild-archive.log": ""])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await LogExcerptSearch.search(in: folder, hints: []) == .nothing)
    }

    @Test func theErrorAppleNamesComesFirst() throws {
        let result = try scan("compile-error-archive", rules: .build)
        let hints = LogLocationHint.hints(
            issues: [CIIssue(id: "i1", buildActionID: "a", type: .error, message: "Cannot find 'PreviewAccessory' in scope", category: "Xcodebuild", file: CIFileLocation(path: "/Volumes/workspace/repository/acmeapp/Views/Record/Camera/CameraPreview.swift", lineNumber: 52))],
            tests: []
        )

        #expect(hints == [LogLocationHint(fileName: "CameraPreview.swift", line: 52)])
        #expect(LogExcerptSearch.ordered(result.findings, by: hints).map(\.lineNumber) == [28, 12, 20])
        #expect(LogExcerptSearch.ordered(result.findings, by: []).map(\.lineNumber) == [12, 20, 28])
        #expect(LogExcerptSearch.ordered(result.findings, by: [LogLocationHint(fileName: "Other.swift", line: 1)]).map(\.lineNumber) == [12, 20, 28])
    }

    @Test func hintsComeFromErrorsAndFailedTestsOnly() {
        let issues = [
            CIIssue(id: "w", buildActionID: "a", type: .warning, message: nil, category: nil, file: CIFileLocation(path: "/x/W.swift", lineNumber: 1)),
            CIIssue(id: "e", buildActionID: "a", type: .error, message: nil, category: nil, file: CIFileLocation(path: "/x/E.swift", lineNumber: 2)),
            CIIssue(id: "e2", buildActionID: "a", type: .error, message: nil, category: nil, file: CIFileLocation(path: "/y/E.swift", lineNumber: 2)),
            CIIssue(id: "n", buildActionID: "a", type: .error, message: nil, category: "ExportArchiveStep", file: nil),
        ]
        let tests = [
            CITestResult(id: "t", buildActionID: "a", className: "C", name: "n", status: .failure, message: nil, file: CIFileLocation(path: "ScoreTests.swift", lineNumber: 49), devices: []),
            CITestResult(id: "u", buildActionID: "a", className: "C", name: "m", status: .success, message: nil, file: CIFileLocation(path: "OkTests.swift", lineNumber: 3), devices: []),
        ]

        #expect(LogLocationHint.hints(issues: issues, tests: tests) == [LogLocationHint(fileName: "E.swift", line: 2), LogLocationHint(fileName: "ScoreTests.swift", line: 49)])
    }
}

struct LogFileReaderTests {
    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reader-\(UUID().uuidString).log")
        try Data(bytes).write(to: url)
        return url
    }

    private func lines(_ bytes: [UInt8]) throws -> [String] {
        let url = try file(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        var found: [String] = []
        try LogFileReader.forEachLine(in: url) { found.append($0) }
        return found
    }

    @Test func linesAreSplitOnNewlinesAndTheLastOneNeedsNoNewline() throws {
        #expect(try lines(Array("a\nb\n\nc".utf8)) == ["a", "b", "", "c"])
        #expect(try lines(Array("a\nb\n".utf8)) == ["a", "b"])
        #expect(try lines(Array("a\r\nb\r\n".utf8)) == ["a", "b"])
        #expect(try lines([]) == [])
        #expect(try lines(Array("\n".utf8)) == [""])
    }

    @Test func aHugeLineKeepsItsStartAndNeverTheRest() throws {
        let huge = Array("start ".utf8) + [UInt8](repeating: 0x78, count: 400_000)
        let found = try lines(huge + [0x0A] + Array("next\n".utf8))

        #expect(found.count == 2)
        #expect(found[0].hasPrefix("start xxx"))
        #expect(found[0].utf8.count == LogFileReader.maximumLineBytes)
        #expect(found[1] == "next")
    }

    @Test func aLineCrossingTwoChunksIsWhole() throws {
        let row = String(repeating: "x", count: 99) + "\n"
        let count = LogFileReader.chunkSize * 2 / row.utf8.count + 1
        let found = try lines(Array(String(repeating: row, count: count).utf8))

        #expect(found.count == count)
        #expect(found.allSatisfy { $0 == String(repeating: "x", count: 99) })
    }

    @Test func aMissingFileThrows() {
        #expect(throws: (any Error).self) {
            try LogFileReader.forEachLine(in: FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).log")) { _ in }
        }
    }
}

struct LogArchiveChoiceTests {
    private func bundle(_ id: String, _ name: String, type: String = "LOG_BUNDLE") -> CIArtifact {
        CIArtifact(id: id, buildActionID: "a", fileType: type, fileName: name, fileSize: 1, downloadURL: nil)
    }

    private var testAction: [CIArtifact] {
        [
            bundle("r", "App Build 359 XCResult for Tests build-for-testing.xcresult.zip", type: "RESULT_BUNDLE"),
            bundle("b", "App Build 359 Logs for Tests build-for-testing.zip"),
            bundle("d1", "App Build 359 Logs for Tests test-without-building on iPhone 16 (default runtime).zip"),
            bundle("d2", "App Build 359 Logs for Tests test-without-building on iPhone 16 Pro Max (default runtime).zip"),
            bundle("d3", "App Build 359 Logs for Tests test-without-building on iPhone SE (3rd generation) (default runtime).zip"),
        ]
    }

    @Test func aSingleArchiveIsTheOne() {
        #expect(LogArchiveChoice.pick(from: [bundle("only", "Logs.zip")], signals: .init())?.id == "only")
        #expect(LogArchiveChoice.pick(from: [bundle("x", "Tests.xcresult.zip", type: "RESULT_BUNDLE")], signals: .init()) == nil)
        #expect(LogArchiveChoice.pick(from: [], signals: .init()) == nil)
    }

    @Test func aCompileErrorIsInTheBuildArchive() {
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(errorCount: 1))?.id == "b")
    }

    @Test func aFailedTestIsInTheArchiveOfItsDevice() {
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(testFailureCount: 1, failedDevices: ["iPhone SE (3rd generation)"]))?.id == "d3")
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(testFailureCount: 1, failedDevices: ["iPhone 16 Pro Max"]))?.id == "d2")
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(testFailureCount: 1, failedDevices: ["iPhone 16"]))?.id == "d1")
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(errorCount: 2, testFailureCount: 1, failedDevices: ["iPhone SE (3rd generation)"]))?.id == "d3")
    }

    @Test func withNothingKnownTheFirstDevicesArchiveIsTaken() {
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init())?.id == "d1")
        #expect(LogArchiveChoice.pick(from: testAction, signals: .init(testFailureCount: 1, failedDevices: ["iPad"]))?.id == "d1")
        let onlyBuild = [bundle("b", "Logs for Tests build-for-testing.zip"), bundle("x", "Other.zip")]
        #expect(LogArchiveChoice.pick(from: onlyBuild, signals: .init())?.id == "b")
    }

    @Test func theSignalsComeFromTheActionAndItsTestResults() {
        let action = CIBuildAction(
            id: "a", buildRunID: "r", name: "Test", actionType: .test, startedDate: nil, finishedDate: nil, executionProgress: .complete,
            completionStatus: .failed, isRequiredToPass: true, issueCounts: CIIssueCounts(analyzerWarnings: 0, errors: 0, testFailures: 3, warnings: 5)
        )
        func test(_ id: String, _ devices: [(String, CITestStatus)]) -> CITestResult {
            CITestResult(
                id: id, buildActionID: "a", className: nil, name: id, status: .failure, message: nil, file: nil,
                devices: devices.map { CITestDeviceResult(deviceName: $0.0, osVersion: "27", status: $0.1, duration: 1) }
            )
        }
        let signals = LogArchiveChoice.Signals(action: action, tests: [
            test("1", [("iPhone SE", .failure), ("iPhone 16", .success)]),
            test("2", [("iPhone SE", .failure), ("iPhone 16", .failure)]),
            test("3", [("iPad", .success)]),
        ])

        #expect(signals == LogArchiveChoice.Signals(errorCount: 0, testFailureCount: 3, failedDevices: ["iPhone SE", "iPhone 16"]))
        #expect(LogArchiveChoice.Signals(action: action, tests: nil).failedDevices.isEmpty)
    }
}

struct LogExcerptFormatTests {
    @Test func theBuildMachinesCheckoutPathIsTakenOff() {
        #expect(
            LogExcerptFormat.line("/Volumes/workspace/repository/acmeapp/Views/PanelFold.swift:72:22: error: no member")
                == "acmeapp/Views/PanelFold.swift:72:22: error: no member"
        )
        #expect(LogExcerptFormat.line("cd /Volumes/workspace/repository/App && build") == "cd App && build")
        #expect(LogExcerptFormat.line("a '/Volumes/workspace/repository/X.swift' and \"/Volumes/workspace/repository/Y.swift\"") == "a 'X.swift' and \"Y.swift\"")
        #expect(LogExcerptFormat.line("nothing to change at /Applications/Xcode.app/File.swift:1:1") == "nothing to change at /Applications/Xcode.app/File.swift:1:1")
        #expect(LogExcerptFormat.line("") == "")
    }

    @Test func theExcerptReadsAsTextWithTheErrorMarked() throws {
        let finding = try #require(try scan("scheme-missing", rules: .bare).findings.first)
        let text = LogExcerptFormat.text(of: finding)
        let rows = text.split(separator: "\n").map(String.init)

        #expect(rows.count == 4)
        #expect(rows.last?.hasPrefix("> 5  xcodebuild: error: The project named") == true)
        #expect(rows.first?.hasPrefix("  2  ") == true)
    }
}

struct LogExcerptPromptTests {
    private func run() -> CIBuildRun {
        CIBuildRun(
            id: "run-1", productID: "p1", number: 42, createdDate: nil, startedDate: nil, finishedDate: nil, executionProgress: .complete,
            completionStatus: .failed, startReason: nil, workflowID: nil, workflowName: "Release", sourceBranchOrTag: "main"
        )
    }

    private func prompt(_ excerpt: LogExcerpt?) -> BuildFailurePrompt {
        BuildFailurePrompt(
            run: run(), product: nil, workflow: nil, actions: [], extras: nil, reference: nil,
            logExcerpt: excerpt.map { BuildFailurePrompt.LogSection(actionName: "Archive - iOS", excerpt: $0) }
        )
    }

    @Test func theSectionIsThereOnlyWithAnExcerpt() throws {
        #expect(!prompt(nil).text.contains("## Log excerpt"))
        let result = try scan("compile-error-archive", rules: .build)
        let text = prompt(LogExcerpt(fileName: "xcodebuild-archive.log", totalLines: result.totalLines, findings: result.findings)).text

        #expect(text.contains("## Log excerpt\nAction \"Archive - iOS\", file xcodebuild-archive.log (78 lines)."))
        #expect(text.contains("    > 12  acmeapp/Views/Components/Row/PanelFold.swift:72:22: error: value of type 'GeometryProxy' has no member 'reservedRegions'"))
        #expect(text.contains("    > 28  acmeapp/Views/Record/Camera/CameraPreview.swift:52:21: error: cannot find 'PreviewAccessory' in scope"))
        #expect(!text.contains("/Volumes/workspace/repository/"))
        #expect(!text.contains("https://"))
    }

    @Test func fortyLinesAtMostAreAttached() {
        let findings = (0..<20).map { index -> LogFinding in
            let base = index * 100
            let lines = (0..<7).map { LogLine(number: base + $0, text: "line \(base + $0)") }
            return LogFinding(family: .compile, line: lines[3], before: Array(lines[..<3]), after: Array(lines[4...]), location: nil)
        }
        let text = prompt(LogExcerpt(fileName: "xcodebuild-archive.log", totalLines: 5000, findings: findings)).text
        let section = text.components(separatedBy: "## Log excerpt\n")[1]
        let logLines = section.split(separator: "\n").filter { $0.hasPrefix("    ") && !$0.contains("...") }

        #expect(logLines.count <= BuildFailurePrompt.maximumExcerptLines)
        #expect(logLines.count == 35)
        #expect(section.contains("5 of 20 shown"))
    }
}
