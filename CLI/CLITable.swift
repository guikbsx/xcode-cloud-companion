import Foundation

/// A plain-text table that fits the terminal: the widest columns give way first, cut with an ellipsis.
nonisolated struct CLITable: Equatable, Sendable {
    static let gap = 2
    static let minimumColumnWidth = 6

    var headers: [String]
    var rows: [[String]] = []
    var rightAligned: Set<Int> = []
    /// Columns that are never cut: the ones a reader copies, such as a build's reference.
    var uncut: Set<Int> = []

    func render(width: Int) -> String {
        guard !headers.isEmpty else { return "" }
        var widths = headers.indices.map { column in
            ([headers[column]] + rows.map { column < $0.count ? $0[column] : "" }).map(\.count).max() ?? 0
        }
        let available = max(width, headers.count * (Self.minimumColumnWidth + Self.gap)) - Self.gap * (headers.count - 1)
        let shrinkable = widths.indices.filter { !uncut.contains($0) }
        while widths.reduce(0, +) > available, let widest = shrinkable.max(by: { widths[$0] < widths[$1] }), widths[widest] > Self.minimumColumnWidth {
            widths[widest] -= 1
        }
        let lines = ([headers] + rows).map { row in
            headers.indices.map { column -> String in
                let cell = Self.fit(column < row.count ? row[column] : "", to: widths[column])
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return rightAligned.contains(column) ? padding + cell : cell + padding
            }
            .joined(separator: String(repeating: " ", count: Self.gap))
            .replacing(/\s+$/, with: "")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fit(_ text: String, to width: Int) -> String {
        let flat = text.replacing(/\s*\n\s*/, with: " ")
        guard flat.count > width else { return flat }
        return width > 1 ? String(flat.prefix(width - 1)) + "…" : String(flat.prefix(width))
    }
}

/// English, fixed wording: the command's tables read the same on every Mac.
nonisolated enum CLIText {
    static let estimateFootnote = "~ Estimate, not an official Apple figure."

    static func minutes(_ minutes: Double, estimated: Bool = false) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let text = rounded >= 60 ? "\(rounded / 60)h \(String(format: "%02d", rounded % 60))m" : "\(rounded)m"
        return estimated ? "~\(text)" : text
    }

    static func duration(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds >= 3600 {
            return "\(seconds / 3600)h \(String(format: "%02d", seconds % 3600 / 60))m"
        }
        return seconds >= 60 ? "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" : "\(seconds)s"
    }

    static func date(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    static func timeLeft(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
        }
        return "\(seconds / 3_600)h \(String(format: "%02d", seconds % 3_600 / 60))m"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func fileSize(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_000: "\(bytes) B"
        case ..<1_000_000: String(format: "%.0f kB", Double(bytes) / 1_000)
        case ..<1_000_000_000: String(format: "%.1f MB", Double(bytes) / 1_000_000)
        default: String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
        }
    }

    /// Label and value lines with the values aligned.
    static func fields(_ fields: [(String, String)]) -> String {
        let width = fields.map(\.0.count).max() ?? 0
        return fields.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }.joined(separator: "\n") + "\n"
    }
}
