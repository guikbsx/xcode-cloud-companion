import Foundation

/// The colours an app can carry in the menu: six system hues told apart by lightness as well as hue.
nonisolated enum AppSwatch: Hashable, Sendable {
    case blue, cyan, yellow, purple, orange, mint
    /// Beyond the sixth app, so no hue is claimed twice.
    case gray
    /// A colour of the app's own: its icon's, or one chosen for it.
    case icon(SwatchColor)

    /// The system hues in the order they are handed out, `gray` last. A saved palette names them by their place here.
    static let system: [AppSwatch] = [.blue, .cyan, .yellow, .purple, .orange, .mint, .gray]
}

/// One stable colour per app: the dominant colour of its icon. An app without an icon, or whose icon has no hue,
/// takes a system swatch instead: the first free one goes to the biggest consumer, then it stays with the app for as
/// long as the app exists, so a colour never changes meaning from one day to the next.
nonisolated struct AppPalette: Codable, Sendable, Equatable {
    /// What an icon gave, kept so that an icon is read once.
    struct IconReading: Codable, Sendable, Equatable {
        /// `AppIconCache.fingerprint` of the icon that was read.
        var icon: String
        /// Nil for an icon with no hue of its own.
        var color: SwatchColor?
    }

    /// The colour someone gave an app, which goes before its icon's.
    enum Choice: Codable, Sendable, Hashable {
        /// One of the system hues, by its place in `AppSwatch.system`.
        case system(Int)
        case custom(SwatchColor)
    }

    private(set) var swatchIndexByApp: [String: Int] = [:]
    private(set) var iconReadingByApp: [String: IconReading] = [:]
    private(set) var choiceByApp: [String: Choice] = [:]

    private static let grayIndex = AppSwatch.system.count - 1

    init() {}

    /// A palette saved before icons gave colours has no readings.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        swatchIndexByApp = try container.decodeIfPresent([String: Int].self, forKey: .swatchIndexByApp) ?? [:]
        iconReadingByApp = try container.decodeIfPresent([String: IconReading].self, forKey: .iconReadingByApp) ?? [:]
        choiceByApp = try container.decodeIfPresent([String: Choice].self, forKey: .choiceByApp) ?? [:]
    }

    /// `ranking` lists every app that exists, biggest consumer first; apps no longer listed give their colour back.
    /// Returns whether anything changed, so the caller only saves when needed.
    @discardableResult
    mutating func update(ranking: [String]) -> Bool {
        let before = self
        let existing = Set(ranking)
        swatchIndexByApp = swatchIndexByApp.filter { existing.contains($0.key) }
        iconReadingByApp = iconReadingByApp.filter { existing.contains($0.key) }
        choiceByApp = choiceByApp.filter { existing.contains($0.key) }

        var used = Set(swatchIndexByApp.values)
        for app in ranking where swatchIndexByApp[app] == nil {
            let free = (0..<Self.grayIndex).first { !used.contains($0) }
            swatchIndexByApp[app] = free ?? Self.grayIndex
            if let free { used.insert(free) }
        }
        return self != before
    }

    /// Whether `icon` (a fingerprint) is still to be read for `app`.
    func needsReading(ofIcon icon: String, for app: String) -> Bool {
        iconReadingByApp[app]?.icon != icon
    }

    mutating func setIconReading(_ reading: IconReading, for app: String) {
        iconReadingByApp[app] = reading
    }

    /// Every existing app, the ones consuming this cycle first (biggest first), then the idle ones by name.
    static func ranking(byConsumption consuming: [String], allApps: [String]) -> [String] {
        let existing = Set(allApps)
        let first = consuming.filter(existing.contains)
        let rest = existing.subtracting(first).sorted()
        return first + rest
    }

    func choice(for app: String) -> Choice? {
        choiceByApp[app]
    }

    /// Nil gives the app back the colour of its icon.
    mutating func choose(_ choice: Choice?, for app: String) {
        choiceByApp[app] = choice
    }

    func swatch(for app: String) -> AppSwatch {
        switch choiceByApp[app] {
        case .system(let index)? where AppSwatch.system.indices.contains(index): AppSwatch.system[index]
        case .custom(let color)?: .icon(color.legible)
        default: defaultSwatch(for: app)
        }
    }

    /// The colour an app has while none is chosen for it: its icon's, else its system swatch.
    func defaultSwatch(for app: String) -> AppSwatch {
        if let color = iconReadingByApp[app]?.color {
            return .icon(color.legible)
        }
        guard let index = swatchIndexByApp[app], AppSwatch.system.indices.contains(index) else { return .gray }
        return AppSwatch.system[index]
    }

    /// Whether the app's default colour comes from its icon, which is what the interface then calls it.
    func hasIconColor(_ app: String) -> Bool {
        iconReadingByApp[app]?.color != nil
    }
}

nonisolated struct AppPaletteStore: Sendable {
    var key = AccountDefaults.key(AccountDefaults.palette, accountID: AccountRegistry.firstAccountID)

    /// Each account colours its own apps.
    static func account(_ id: String) -> AppPaletteStore {
        AppPaletteStore(key: AccountDefaults.key(AccountDefaults.palette, accountID: id))
    }

    func load(from defaults: UserDefaults = .standard) -> AppPalette {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppPalette.self, from: $0) } ?? AppPalette()
    }

    func save(_ palette: AppPalette, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(palette), forKey: key)
    }
}

nonisolated extension AppPaletteStore {
    /// The saved colours brought up to date with the apps that exist; saved again only when something changed.
    func refreshed(for snapshot: BuildSnapshot, summary: UsageSummary?, defaults: UserDefaults = .standard) -> AppPalette {
        var palette = load(from: defaults)
        let ranking = AppPalette.ranking(byConsumption: summary?.appsByConsumption ?? [], allApps: snapshot.products.map(\.name))
        if palette.update(ranking: ranking) {
            save(palette, to: defaults)
        }
        return palette
    }
}
