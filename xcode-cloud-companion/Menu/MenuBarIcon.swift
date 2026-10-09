import AppKit

/// The menu bar image, in one piece: the Cumulus symbol alone, or the same cloud with its badge (`logo.badge`),
/// the badge in the state's colour. No view is laid over the button.
enum MenuBarIcon {
    /// Measuring dims the cloud, without any animation.
    static let measuringOpacity: CGFloat = 0.6

    static func image(badge: MenuBarBadge?, measuring: Bool) -> NSImage? {
        guard let badge else { return measuring ? measuringCloud : restingCloud }
        guard let badgedSymbol else { return nil }
        // Drawn on demand so the cloud takes the label colour of the menu bar it is drawn in (light or dark),
        // which a symbol configured once would resolve from the app's appearance instead.
        let image = NSImage(size: badgedSymbol.size, flipped: false) { rect in
            let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
            let cloud = label.withAlphaComponent(label.alphaComponent * (measuring ? measuringOpacity : 1))
            // Palette colours follow the symbol's levels: the badge is primary, the cloud secondary.
            let configuration = NSImage.SymbolConfiguration(paletteColors: [badge.color, cloud])
            badgedSymbol.withSymbolConfiguration(configuration)?.draw(in: rect)
            return true
        }
        image.accessibilityDescription = String(localized: "Cumulus")
        return image
    }

    // Symbols load by name with `symbolName:`: the app icon is also called "logo".
    private static let symbol = NSImage(symbolName: "logo", bundle: .main, variableValue: 1)
    private static let badgedSymbol = NSImage(symbolName: "logo.badge", bundle: .main, variableValue: 1)

    private static let restingCloud = framed(opacity: 1)
    private static let measuringCloud = framed(opacity: measuringOpacity)

    /// The cloud alone, in a frame the size of the badged symbol with the cloud at the same place,
    /// so the cloud and the percentage beside it do not move when a badge comes or goes. Still a template.
    private static func framed(opacity: CGFloat) -> NSImage? {
        guard let symbol else { return nil }
        let size = badgedSymbol?.size ?? symbol.size
        // Both symbols start the cloud at their top left corner; the badge only adds room to the right and below.
        let cloud = symbol.drawnBounds
        let badged = badgedSymbol?.drawnBounds ?? cloud
        let origin = NSPoint(x: badged.minX - cloud.minX, y: badged.maxY - cloud.maxY)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: origin, size: symbol.size), from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Cumulus")
        return image
    }
}
