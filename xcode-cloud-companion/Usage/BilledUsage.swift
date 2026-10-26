import Foundation

/// One line of App Store Connect's usage export: the minutes Apple actually billed for a build.
nonisolated struct BilledBuild: Codable, Sendable, Equatable {
    var product: String
    var buildNumber: Int
    var workflow: String
    var startedAt: Date
    var minutes: Int

    var key: String { "\(product)#\(buildNumber)" }
}

nonisolated struct UsageExport: Sendable, Equatable {
    var builds: [BilledBuild]
    var coverage: DateInterval
}

nonisolated enum UsageImportError: Error, Equatable, Sendable {
    case unreadable
    case missingColumns([String])
    case invalidRow(line: Int)
    case empty

    var message: String {
        switch self {
        case .unreadable:
            String(localized: "This file can’t be read as text.")
        case .missingColumns(let columns):
            String(localized: "This isn’t an Xcode Cloud usage export: missing \(columns.formatted(.list(type: .and))).")
        case .invalidRow(let line):
            String(localized: "Line \(line) of the usage export can’t be read.")
        case .empty:
            String(localized: "The usage export contains no build.")
        }
    }
}

nonisolated enum UsageExportParser {
    static var fileNamePattern: Regex<(Substring, Substring, Substring)> { /^usage_(\d{4}-\d{2}-\d{2})_(\d{4}-\d{2}-\d{2})\.csv$/ }

    private enum Column: String, CaseIterable {
        case buildNumber = "Build Number"
        case product = "Product"
        case startedAt = "Started At"
        case minutes = "Usage (Minutes)"
        case workflow = "Workflow"
    }

    static func isUsageExport(fileName: String) -> Bool {
        fileName.wholeMatch(of: fileNamePattern) != nil
    }

    static func parse(_ data: Data, fileName: String) throws(UsageImportError) -> UsageExport {
        guard let text = String(data: data, encoding: .utf8) else { throw .unreadable }
        let rows = csvRows(text)
        guard let header = rows.first else { throw .empty }

        var indexes: [Column: Int] = [:]
        for column in Column.allCases {
            if let index = header.firstIndex(of: column.rawValue) { indexes[column] = index }
        }
        let missing = Column.allCases.filter { indexes[$0] == nil }.map(\.rawValue)
        guard missing.isEmpty else { throw .missingColumns(missing) }

        var builds: [BilledBuild] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            func field(_ column: Column) -> String? {
                indexes[column].flatMap { $0 < row.count ? row[$0] : nil }
            }
            guard let number = field(.buildNumber).flatMap({ Int($0) }),
                  let product = field(.product), !product.isEmpty,
                  let started = field(.startedAt).flatMap({ try? Date.ISO8601FormatStyle().parse($0) }),
                  let minutes = field(.minutes).flatMap({ Int($0) })
            else { throw .invalidRow(line: offset + 2) }
            builds.append(BilledBuild(product: product, buildNumber: number, workflow: field(.workflow) ?? "", startedAt: started, minutes: minutes))
        }
        guard !builds.isEmpty else { throw .empty }

        return UsageExport(builds: builds, coverage: coverage(fileName: fileName) ?? coverage(of: builds))
    }

    /// The file name carries the exported range, e.g. `usage_2026-09-09_2026-10-09.csv`; the last day is included.
    static func coverage(fileName: String) -> DateInterval? {
        guard let match = fileName.wholeMatch(of: fileNamePattern) else { return nil }
        let style = Date.ISO8601FormatStyle().year().month().day()
        guard let start = try? style.parse(String(match.1)),
              let lastDay = try? style.parse(String(match.2)),
              lastDay >= start
        else { return nil }
        return DateInterval(start: start, end: lastDay.addingTimeInterval(24 * 3600))
    }

    private static func coverage(of builds: [BilledBuild]) -> DateInterval {
        let dates = builds.map(\.startedAt)
        let start = dates.min() ?? .distantPast
        return DateInterval(start: start, end: max(start, dates.max() ?? start))
    }

    /// RFC 4180 subset: quoted fields, doubled quotes, commas and line breaks inside quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        func handle(_ character: Character) {
            switch character {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r": row.append(field); rows.append(row); row = []; field = ""
            default: field.append(character)
            }
        }
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            handle(next)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                handle(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

/// Billed minutes kept between imports, keyed by product and build number.
nonisolated struct UsageLedger: Codable, Sendable, Equatable {
    static let retention: TimeInterval = 120 * 24 * 3600

    var builds: [String: BilledBuild] = [:]
    var lastImport: Date?
    var lastCoverage: DateInterval?
    /// File name → modification date, so a file already read is not imported twice.
    var importedFiles: [String: Date] = [:]
    /// Builds both billed and measured: kept past `retention` and past the build cache, the estimate learns from them.
    var calibration = UsageCalibration()

    func hasImported(fileName: String, modifiedAt: Date) -> Bool {
        importedFiles[fileName] == modifiedAt
    }

    mutating func merge(_ export: UsageExport, fileName: String, modifiedAt: Date, importedAt: Date) {
        for build in export.builds {
            builds[build.key] = build
        }
        importedFiles[fileName] = modifiedAt
        lastImport = importedAt
        if lastCoverage.map({ export.coverage.end >= $0.end }) ?? true {
            lastCoverage = export.coverage
        }
        let oldest = importedAt.addingTimeInterval(-Self.retention)
        builds = builds.filter { $0.value.startedAt >= oldest }
    }

    func billedBuild(product: String, buildNumber: Int) -> BilledBuild? {
        builds["\(product)#\(buildNumber)"]
    }
}

nonisolated extension UsageLedger {
    // A ledger written before a field existed still loads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        builds = try container.decodeIfPresent([String: BilledBuild].self, forKey: .builds) ?? [:]
        lastImport = try container.decodeIfPresent(Date.self, forKey: .lastImport)
        lastCoverage = try container.decodeIfPresent(DateInterval.self, forKey: .lastCoverage)
        importedFiles = try container.decodeIfPresent([String: Date].self, forKey: .importedFiles) ?? [:]
        calibration = try container.decodeIfPresent(UsageCalibration.self, forKey: .calibration) ?? UsageCalibration()
    }
}
