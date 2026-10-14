import Foundation

/// One entry of Apple's system status page about Xcode Cloud. No end means it goes on.
nonisolated struct AppleStatusEvent: Sendable, Equatable {
    let start: Date
    let end: Date?

    var isOngoing: Bool { end == nil }

    /// Whether the event overlaps the span a build was alive; an event still going on lasts until `now`.
    func covers(from buildStart: Date, to buildEnd: Date, now: Date) -> Bool {
        buildStart <= (end ?? now) && start <= buildEnd
    }
}

/// What a read of the page says about Xcode Cloud. `unknown` is any page the decoder does not recognise: it never claims
/// that nothing is wrong.
nonisolated enum AppleStatusReading: Sendable, Equatable {
    case events([AppleStatusEvent])
    case unknown
}

/// Reads `system_status_en_US.js`: `jsonCallback({ "services": [ { "serviceName": …, "events": […] } ] });`.
/// Every field is checked by hand; a page that differs in any way from what was seen is `unknown`, never an error.
nonisolated enum AppleStatusDecoder {
    static let serviceName = "Xcode Cloud"

    static func decode(_ data: Data) -> AppleStatusReading {
        guard let text = String(data: data, encoding: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: Data(unwrapped(text).utf8))) as? [String: Any],
              let services = root["services"] as? [Any]
        else { return .unknown }
        let matching = services.compactMap { $0 as? [String: Any] }.filter {
            ($0["serviceName"] as? String)?.trimmingCharacters(in: .whitespaces) == serviceName
        }
        guard !matching.isEmpty else { return .unknown }
        var events: [AppleStatusEvent] = []
        for service in matching {
            guard let raw = service["events"] as? [Any] else { return .unknown }
            for item in raw {
                guard let event = (item as? [String: Any]).flatMap(event(from:)) else { return .unknown }
                events.append(event)
            }
        }
        return .events(events)
    }

    private static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{"), let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<close])
    }

    private enum Milliseconds {
        case missing
        case value(Double)
        case invalid
    }

    private static func milliseconds(_ raw: Any?) -> Milliseconds {
        guard let raw, !(raw is NSNull) else { return .missing }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .invalid }
        return .value(number.doubleValue)
    }

    /// An event is still going on when it has no end, a null end or an end of zero, whatever its status text says.
    private static func event(from raw: [String: Any]) -> AppleStatusEvent? {
        guard case .value(let start) = milliseconds(raw["epochStartDate"]), start > 0 else { return nil }
        let end: Date?
        switch milliseconds(raw["epochEndDate"]) {
        case .missing: end = nil
        case .value(let value): end = value > 0 ? Date(timeIntervalSince1970: value / 1000) : nil
        case .invalid: return nil
        }
        return AppleStatusEvent(start: Date(timeIntervalSince1970: start / 1000), end: end)
    }
}

/// What the app knows from its last successful read. An event still going on is only known for a while: a page not read
/// for half an hour says nothing about now.
nonisolated struct AppleStatusKnowledge: Sendable, Equatable {
    static let ongoingLifetime: TimeInterval = 30 * 60

    let events: [AppleStatusEvent]
    let readAt: Date

    func current(at now: Date) -> [AppleStatusEvent] {
        events.filter { !$0.isOngoing || now.timeIntervalSince(readAt) <= Self.ongoingLifetime }
    }

    func ongoing(at now: Date) -> AppleStatusEvent? {
        current(at: now).first(where: \.isOngoing)
    }

    /// The earliest event that covers the build's life, if there is one.
    func event(covering run: CIBuildRun, now: Date) -> AppleStatusEvent? {
        guard let start = run.startedDate ?? run.createdDate ?? run.finishedDate else { return nil }
        let end = run.finishedDate ?? now
        return current(at: now).filter { $0.covers(from: start, to: end, now: now) }.min { $0.start < $1.start }
    }
}
