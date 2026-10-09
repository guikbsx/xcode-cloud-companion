import Foundation

/// The colours an app can carry in the menu: six system hues told apart by lightness as well as hue.
nonisolated enum AppSwatch: Int, CaseIterable, Sendable {
    case blue, cyan, yellow, purple, orange, mint
    /// Beyond the sixth app, so no hue is claimed twice.
    case gray
}

/// One stable colour per app: the first free swatch goes to the biggest consumer, then it stays with the app
/// for as long as the app exists, so a colour never changes meaning from one day to the next.
nonisolated struct AppPalette: Codable, Sendable, Equatable {
    private(set) var swatchIndexByApp: [String: Int] = [:]

    /// `ranking` lists every app that exists, biggest consumer first; apps no longer listed give their colour back.
    /// Returns whether anything changed, so the caller only saves when needed.
    @discardableResult
    mutating func update(ranking: [String]) -> Bool {
        let before = swatchIndexByApp
        let existing = Set(ranking)
        swatchIndexByApp = swatchIndexByApp.filter { existing.contains($0.key) }

        var used = Set(swatchIndexByApp.values)
        for app in ranking where swatchIndexByApp[app] == nil {
            let free = (0..<AppSwatch.gray.rawValue).first { !used.contains($0) }
            swatchIndexByApp[app] = free ?? AppSwatch.gray.rawValue
            if let free { used.insert(free) }
        }
        return swatchIndexByApp != before
    }

    /// Every existing app, the ones consuming this cycle first (biggest first), then the idle ones by name.
    static func ranking(byConsumption consuming: [String], allApps: [String]) -> [String] {
        let existing = Set(allApps)
        let first = consuming.filter(existing.contains)
        let rest = existing.subtracting(first).sorted()
        return first + rest
    }

    func swatch(for app: String) -> AppSwatch {
        swatchIndexByApp[app].flatMap(AppSwatch.init(rawValue:)) ?? .gray
    }
}

nonisolated struct AppPaletteStore: Sendable {
    var key = "appPalette.assignments"

    func load(from defaults: UserDefaults = .standard) -> AppPalette {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppPalette.self, from: $0) } ?? AppPalette()
    }

    func save(_ palette: AppPalette, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(palette), forKey: key)
    }
}
