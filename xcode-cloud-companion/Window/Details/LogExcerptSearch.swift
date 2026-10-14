import Foundation

/// What was read of an action's unpacked log: the file the errors are in, how long it is, and the errors.
nonisolated struct LogExcerpt: Equatable, Sendable {
    let fileName: String
    let totalLines: Int
    let findings: [LogFinding]

    /// Typical lengths, for the skeleton of the card.
    static let placeholder: LogExcerpt = {
        let lines = (0..<7).map { LogLine(number: 18_407 + $0, text: "error: placeholder text of a log line") }
        return LogExcerpt(
            fileName: "xcodebuild-archive.log", totalLines: 23_870,
            findings: [LogFinding(family: .compile, line: lines[3], before: Array(lines[..<3]), after: Array(lines[4...]), location: nil)]
        )
    }()
}

nonisolated enum LogExcerptOutcome: Equatable, Sendable {
    case found(LogExcerpt)
    /// The log was read and holds no line that says an error.
    case nothing
}

/// Reads a text file one line at a time, in chunks, so that a log of 4 MB or a line of 155 000 characters never sits in memory whole.
nonisolated enum LogFileReader {
    static let chunkSize = 64 * 1024
    /// A line longer than this keeps its start only: the patterns are anchored at the start, and the display cuts far sooner.
    static let maximumLineBytes = 8 * 1024

    static func forEachLine(in url: URL, _ body: (String) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line: [UInt8] = []

        func finishLine() {
            if line.last == 0x0D { line.removeLast() }
            body(String(decoding: line, as: UTF8.self))
            line.removeAll(keepingCapacity: true)
        }

        var hasPending = false
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    finishLine()
                    hasPending = false
                    continue
                }
                hasPending = true
                if line.count < maximumLineBytes { line.append(byte) }
            }
        }
        if hasPending { finishLine() }
    }
}

/// Which of an action's log archives to download when it holds several. An action that tests on four devices has one
/// archive for each device and one for the build that comes before them: a test fails in its device's archive, and a
/// compile error is in the build's.
nonisolated enum LogArchiveChoice {
    struct Signals: Equatable, Sendable {
        var errorCount = 0
        var testFailureCount = 0
        /// Devices a failed test was seen failing on, the most often first.
        var failedDevices: [String] = []

        init(action: CIBuildAction, tests: [CITestResult]?) {
            errorCount = action.issueCounts?.errors ?? 0
            testFailureCount = action.issueCounts?.testFailures ?? 0
            var counts: [String: Int] = [:]
            for test in tests ?? [] {
                for device in test.devices where device.status.isFailure { counts[device.deviceName, default: 0] += 1 }
            }
            failedDevices = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
        }

        init(errorCount: Int = 0, testFailureCount: Int = 0, failedDevices: [String] = []) {
            self.errorCount = errorCount
            self.testFailureCount = testFailureCount
            self.failedDevices = failedDevices
        }
    }

    static func pick(from artifacts: [CIArtifact], signals: Signals) -> CIArtifact? {
        let logs = artifacts.filter { $0.fileType == "LOG_BUNDLE" }
        guard logs.count > 1 else { return logs.first }
        let build = logs.first { name(of: $0).contains("build-for-testing") }
        if signals.errorCount > 0, signals.testFailureCount == 0, let build { return build }
        let tests = logs.filter { name(of: $0).contains("test-without-building") }
        for device in signals.failedDevices {
            if let match = tests.first(where: { name(of: $0).contains(" on \(device) (") || name(of: $0).hasSuffix(" on \(device).zip") }) { return match }
        }
        return tests.first ?? build ?? logs.first
    }

    private static func name(of artifact: CIArtifact) -> String {
        artifact.fileName ?? ""
    }
}

/// Looks for the error in an unpacked log archive. Only the files that hold the output of `xcodebuild`, of the package
/// resolution or of the export are read: the user's own scripts (`ci_*.log`) and Apple's distribution logs are noisy, and
/// a line in them proves nothing.
nonisolated enum LogExcerptSearch {
    struct Candidate: Equatable, Sendable {
        let url: URL
        let displayName: String
        let rules: LogErrorScanner.Rules
        fileprivate let rank: Int
    }

    @concurrent static func search(in folder: URL, hints: [LogLocationHint]) async -> LogExcerptOutcome {
        for candidate in candidates(in: folder) {
            if Task.isCancelled { break }
            var scanner = LogErrorScanner(rules: candidate.rules)
            do {
                try LogFileReader.forEachLine(in: candidate.url) { scanner.feed($0) }
            } catch {
                continue
            }
            let result = scanner.finish()
            guard !result.findings.isEmpty else { continue }
            return .found(LogExcerpt(fileName: candidate.displayName, totalLines: result.totalLines, findings: ordered(result.findings, by: hints)))
        }
        return .nothing
    }

    /// The errors Apple names come first, each group in the order of the log.
    static func ordered(_ findings: [LogFinding], by hints: [LogLocationHint]) -> [LogFinding] {
        guard !hints.isEmpty else { return findings }
        let named = findings.filter { finding in hints.contains { $0.matches(finding) } }
        return named + findings.filter { finding in !named.contains { $0.id == finding.id } }
    }

    /// The files worth reading, the ones that carry a compile error or a test first.
    static func candidates(in folder: URL) -> [Candidate] {
        let manager = FileManager.default
        guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [Candidate] = []
        for case let url as URL in files {
            let name = url.lastPathComponent
            if name.hasSuffix(".xcdistributionlogs") {
                files.skipDescendants()
                continue
            }
            guard name.hasSuffix(".log"), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let candidate = candidate(for: url) { found.append(candidate) }
        }
        return found.sorted { ($0.rank, $0.url.path(percentEncoded: false)) < ($1.rank, $1.url.path(percentEncoded: false)) }
    }

    private static func candidate(for url: URL) -> Candidate? {
        let name = url.lastPathComponent
        switch name {
        case "xcodebuild-export-archive.log":
            let parent = url.deletingLastPathComponent().lastPathComponent
            return Candidate(url: url, displayName: parent.hasSuffix("-export-archive-logs") ? "\(parent)/\(name)" : name, rules: .bare, rank: 30)
        case "resolve_package_dependencies.log":
            return Candidate(url: url, displayName: name, rules: .bare, rank: 20)
        case "xcodebuild-archive.log":
            return Candidate(url: url, displayName: name, rules: .build, rank: 0)
        case "xcodebuild-build-for-testing.log":
            return Candidate(url: url, displayName: name, rules: .build, rank: 1)
        case "xcodebuild-test-without-building.log":
            return Candidate(url: url, displayName: name, rules: .build, rank: 2)
        default:
            return name.hasPrefix("xcodebuild-") ? Candidate(url: url, displayName: name, rules: .build, rank: 3) : nil
        }
    }
}

/// How a log line reads in the card and in the text for an AI: the build machine's checkout path is taken off, so that a
/// file is named as it is in the repository.
nonisolated enum LogExcerptFormat {
    static func line(_ text: String) -> String {
        let marker = RepositoryFileLocator.checkoutMarker
        guard text.contains(marker) else { return text }
        var result = ""
        var rest = Substring(text)
        while let found = rest.range(of: marker) {
            let head = rest[..<found.lowerBound]
            let start = head.lastIndex { " \t\"'(<[=".contains($0) }.map(head.index(after:)) ?? head.startIndex
            result += head[..<start]
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    /// “line 1 536 of 2 870”.
    static func position(_ finding: LogFinding, of total: Int) -> String {
        String(localized: "line \(finding.lineNumber.formatted()) of \(total.formatted())", comment: "Where a log excerpt is in its file, e.g. “line 1,536 of 2,870”")
    }

    /// The excerpt as plain text, one log line per row with its number; the error line is marked.
    static func text(of finding: LogFinding) -> String {
        finding.lines.map { row in
            let marker = row.number == finding.lineNumber ? ">" : " "
            return "\(marker) \(row.number)  \(line(row.text))"
        }.joined(separator: "\n")
    }
}
