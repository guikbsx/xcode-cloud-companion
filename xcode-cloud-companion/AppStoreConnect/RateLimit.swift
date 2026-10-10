import Foundation

/// Apple's hourly request budget for one API key, from the `X-Rate-Limit` header of every response:
/// `user-hour-lim:3500;user-hour-rem:500;`.
nonisolated struct RateLimit: Sendable, Equatable {
    let limit: Int
    let remaining: Int

    init(limit: Int, remaining: Int) {
        self.limit = limit
        self.remaining = remaining
    }

    /// Nil when the header is absent or does not carry both values.
    init?(header: String?) {
        guard let header else { return nil }
        var values: [String: Int] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let value = Int(pair[1]) {
                values[pair[0]] = value
            }
        }
        guard let limit = values["user-hour-lim"], let remaining = values["user-hour-rem"] else { return nil }
        self.init(limit: limit, remaining: remaining)
    }

    /// Share of the hourly budget still available, 0...1.
    var fractionRemaining: Double {
        limit > 0 ? min(max(Double(remaining) / Double(limit), 0), 1) : 0
    }
}
