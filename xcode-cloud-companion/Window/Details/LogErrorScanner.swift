import Foundation

/// One line of a log, as shown: without its timestamp and its colour codes, cut at `LogLineCleaner.displayLimit`.
nonisolated struct LogLine: Equatable, Sendable, Identifiable {
    let number: Int
    let text: String

    var id: Int { number }
}

/// A line that says an error, with the lines around it.
nonisolated struct LogFinding: Equatable, Sendable, Identifiable {
    /// The pattern that recognised the line. Nothing looser is ever used: a bare “error” or “failed” also stands in file
    /// names, in distribution logs and in the output of a user's own script.
    enum Family: String, Sendable {
        /// `/path/File.swift:72:22: error: …`, as the Swift compiler prints it.
        case compile
        /// `✘ Test "…" recorded an issue at File.swift:49:25: …`, as Swift Testing prints it.
        case testIssue
        /// `error: …` or `xcodebuild: error: …` alone on its line.
        case xcodebuild
    }

    struct Location: Equatable, Sendable {
        let fileName: String
        let line: Int
    }

    let family: Family
    let line: LogLine
    var before: [LogLine]
    var after: [LogLine]
    let location: Location?

    var id: Int { line.number }
    var lineNumber: Int { line.number }
    var lines: [LogLine] { before + [line] + after }
}

/// The file and line Apple names for a problem. They find the right error in a log better than any text can: the words
/// differ between Apple's issue and the compiler's line, the place does not.
nonisolated struct LogLocationHint: Equatable, Sendable {
    let fileName: String
    let line: Int

    static func hints(issues: [CIIssue], tests: [CITestResult]) -> [LogLocationHint] {
        let places = issues.filter { $0.type == .error || $0.type == .testFailure }.map(\.file)
            + tests.filter { $0.status.isFailure }.map(\.file)
        var seen: Set<String> = []
        return places.compactMap { place -> LogLocationHint? in
            guard let path = place?.path?.nilIfBlank, let line = place?.lineNumber else { return nil }
            let hint = LogLocationHint(fileName: (path as NSString).lastPathComponent, line: line)
            return seen.insert("\(hint.fileName):\(hint.line)").inserted ? hint : nil
        }
    }

    func matches(_ finding: LogFinding) -> Bool {
        finding.location.map { $0.fileName == fileName && $0.line == line } ?? false
    }
}

/// Takes the timestamp and the colour codes off a log line, and cuts it for display.
nonisolated enum LogLineCleaner {
    static let displayLimit = 300

    static func clean(_ raw: String) -> String {
        var utf8 = Substring(raw).utf8
        let prefix = timestampLength(utf8)
        if prefix > 0 { utf8 = utf8.dropFirst(prefix) }
        let text = String(Substring(utf8))
        return text.utf8.contains(0x1B) ? withoutEscapes(text) : text
    }

    static func shortened(_ text: String) -> String {
        guard let end = text.index(text.startIndex, offsetBy: displayLimit, limitedBy: text.endIndex), end < text.endIndex else { return text }
        return String(text[..<end]) + "…"
    }

    /// `2026-10-08T07:58:26.488826248Z` and a tab: the length of that prefix, or 0 when the line does not begin with one.
    private static func timestampLength(_ text: Substring.UTF8View) -> Int {
        var bytes = text.prefix(40).makeIterator()
        var count = 0
        func next() -> UInt8? {
            count += 1
            return bytes.next()
        }
        func isDigit(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return byte >= 0x30 && byte <= 0x39
        }
        let shape: [UInt8?] = [nil, nil, nil, nil, 0x2D, nil, nil, 0x2D, nil, nil, 0x54, nil, nil, 0x3A, nil, nil, 0x3A, nil, nil]
        for expected in shape {
            let byte = next()
            if let expected {
                guard byte == expected else { return 0 }
            } else {
                guard isDigit(byte) else { return 0 }
            }
        }
        var byte = next()
        if byte == 0x2E {
            var digits = 0
            byte = next()
            while isDigit(byte), digits < 9 {
                digits += 1
                byte = next()
            }
            guard digits > 0 else { return 0 }
        }
        guard byte == 0x5A, next() == 0x09 else { return 0 }
        return count
    }

    /// `ESC [ 0;32 m` and the like, which a script's output carries.
    private static func withoutEscapes(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar.value == 0x1B else {
                result.append(scalar)
                continue
            }
            guard let opener = scalars.next() else { break }
            guard opener == "[" else { continue }
            while let next = scalars.next() {
                let isParameter = (next.value >= 0x30 && next.value <= 0x3F) || next.value == 0x20
                if !isParameter { break }
            }
        }
        return String(result)
    }
}

/// Finds the lines of a log that say an error, one line at a time: the lines are fed in order, and nothing of the log is
/// kept but the findings with their three lines on each side. The log's own lines are never searched for “error”.
nonisolated struct LogErrorScanner: Sendable {
    /// Which patterns a file is searched with. The output of `xcodebuild` itself holds compile errors and test issues; the
    /// package resolution and the export hold the bare `error:` lines.
    enum Rules: Sendable {
        case build
        case bare
    }

    struct Result: Equatable, Sendable {
        let totalLines: Int
        let findings: [LogFinding]
    }

    static let maximumFindings = 20
    static let contextLines = 3

    private let rules: Rules
    private var lineCount = 0
    private var recent: [LogLine] = []
    private var findings: [LogFinding] = []
    private var seen: Set<String> = []
    /// Findings from this one on still wait for lines after them.
    private var firstOpen = 0

    init(rules: Rules) {
        self.rules = rules
    }

    mutating func feed(_ raw: String) {
        lineCount += 1
        let text = LogLineCleaner.clean(raw)
        let line = LogLine(number: lineCount, text: LogLineCleaner.shortened(text))

        while firstOpen < findings.count, findings[firstOpen].after.count >= Self.contextLines { firstOpen += 1 }
        for index in firstOpen..<findings.count { findings[index].after.append(line) }

        if findings.count < Self.maximumFindings, let match = Self.match(text, rules: rules), seen.insert(text).inserted {
            findings.append(LogFinding(family: match.family, line: line, before: recent, after: [], location: match.location))
        }
        recent.append(line)
        if recent.count > Self.contextLines { recent.removeFirst() }
    }

    func finish() -> Result {
        Result(totalLines: lineCount, findings: findings)
    }

    // MARK: - Patterns

    static func match(_ text: String, rules: Rules) -> (family: LogFinding.Family, location: LogFinding.Location?)? {
        switch rules {
        case .build:
            if let location = compileLocation(text) { return (.compile, location) }
            if let location = testIssueLocation(text) { return (.testIssue, location) }
            return nil
        case .bare:
            return text.hasPrefix("error: ") || text.hasPrefix("xcodebuild: error: ") ? (.xcodebuild, nil) : nil
        }
    }

    /// `/Volumes/workspace/repository/App/File.swift:72:22: error: …`, from the first column.
    private static func compileLocation(_ text: String) -> LogFinding.Location? {
        guard text.hasPrefix("/"), let marker = text.range(of: ": error: ") else { return nil }
        return location(endingAt: text[..<marker.lowerBound])
    }

    /// `✘ Test "…" recorded an issue at File.swift:49:25: …`, with or without quotes, and with argument values before the place.
    private static func testIssueLocation(_ text: String) -> LogFinding.Location? {
        guard text.hasPrefix("✘ Test "), let marker = text.range(of: " recorded an issue") else { return nil }
        var rest = text[marker.upperBound...]
        while let at = rest.range(of: " at ") {
            rest = rest[at.upperBound...]
            guard let end = rest.range(of: ": ") else { return nil }
            if let found = location(endingAt: rest[..<end.lowerBound]), !rest[..<end.lowerBound].contains(where: \.isWhitespace) { return found }
        }
        return nil
    }

    /// `path:line:column` → the file's name and the line.
    private static func location(endingAt place: Substring) -> LogFinding.Location? {
        let parts = place.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let line = Int(parts[parts.count - 2]), Int(parts[parts.count - 1]) != nil else { return nil }
        let path = parts.dropLast(2).joined(separator: ":")
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : LogFinding.Location(fileName: name, line: line)
    }
}
