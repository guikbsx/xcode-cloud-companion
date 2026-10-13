import AppKit
import SwiftUI

nonisolated extension AppSwatch {
    /// The system hues someone may give an app: `gray` is what an app gets when none is left, not a choice.
    static let choosable = Array(AppSwatch.system.dropLast())

    var colorName: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .cyan: String(localized: "Cyan")
        case .yellow: String(localized: "Yellow")
        case .purple: String(localized: "Purple")
        case .orange: String(localized: "Orange")
        case .mint: String(localized: "Mint")
        case .gray: String(localized: "Gray")
        case .icon: String(localized: "Custom Color")
        }
    }
}

nonisolated extension SwatchColor {
    /// Whatever space the colour was picked in, the palette keeps sRGB.
    init?(_ color: NSColor) {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
    }
}

/// What the interface calls an app's colour: the one chosen for it, else the default it gets.
nonisolated enum AppColorText {
    static func defaultName(hasIconColor: Bool) -> String {
        hasIconColor ? String(localized: "Icon Color") : String(localized: "Default Color")
    }

    static func name(of choice: AppPalette.Choice?, hasIconColor: Bool) -> String {
        switch choice {
        case .system(let index)? where AppSwatch.system.indices.contains(index): AppSwatch.system[index].colorName
        case .custom?: String(localized: "Custom Color")
        default: defaultName(hasIconColor: hasIconColor)
        }
    }
}

/// The colour entries of an app's context menu: a row of dots like the Finder's tags, the name of the one in use,
/// and the way to any other colour.
struct AppColorMenu: View {
    let choice: AppPalette.Choice?
    let defaultSwatch: AppSwatch
    let hasIconColor: Bool
    let choose: (AppPalette.Choice?) -> Void
    let pickOther: () -> Void

    var body: some View {
        Picker(selection: Binding(get: { choice }, set: { choose($0) })) {
            dot(AppColorText.defaultName(hasIconColor: hasIconColor), defaultSwatch).tag(AppPalette.Choice?.none)
            ForEach(AppSwatch.choosable.indices, id: \.self) { index in
                dot(AppSwatch.choosable[index].colorName, AppSwatch.choosable[index]).tag(AppPalette.Choice?.some(.system(index)))
            }
            // A picker needs an entry for its selection: a custom colour gets its own dot while it is the one in use.
            if case .custom(let color)? = choice {
                dot(String(localized: "Custom Color"), .icon(color.legible)).tag(AppPalette.Choice?.some(.custom(color)))
            }
        } label: {
            Text("Color", comment: "Context menu of an app in the sidebar: the row of colours to give the app")
        }
        .pickerStyle(.palette)
        Text(AppColorText.name(of: choice, hasIconColor: hasIconColor))
        Button("Other Color…", action: pickOther)
    }

    private func dot(_ name: String, _ swatch: AppSwatch) -> some View {
        Label(name, systemImage: "circle.fill").tint(swatch.color)
    }
}

/// The system colour panel, aimed at one app at a time.
final class AppColorPanel: NSObject {
    private var onPick: ((SwatchColor) -> Void)?

    func open(with color: NSColor, onPick: @escaping (SwatchColor) -> Void) {
        let panel = NSColorPanel.shared
        // The panel may still be aimed at the app picked before: nothing is told while its colour is set.
        panel.setTarget(nil)
        panel.showsAlpha = false
        panel.color = color
        self.onPick = onPick
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        guard let color = SwatchColor(sender.color) else { return }
        onPick?(color)
    }
}

/// One app of Settings › App Colors: what its colour is, the way back to its default, and a well to change it.
struct AppColorRow: View {
    let session: AccountSession
    let product: CIProduct
    let palette: AppPalette

    var body: some View {
        let choice = palette.choice(for: product.name)
        let hasIconColor = palette.hasIconColor(product.name)
        LabeledContent {
            HStack(spacing: 8) {
                if choice == nil {
                    Text(hasIconColor ? String(localized: "Icon", comment: "Settings, App Colors: the app has the colour of its icon") : String(localized: "Default"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(hasIconColor ? String(localized: "Back to Icon") : String(localized: "Back to Default")) {
                        session.chooseColor(nil, forApp: product.name)
                    }
                    .buttonStyle(.link)
                }
                ColorPicker(
                    selection: Binding(
                        get: { palette.swatch(for: product.name).color },
                        set: { picked in
                            guard let color = SwatchColor(NSColor(picked)) else { return }
                            session.chooseColor(.custom(color), forApp: product.name)
                        }
                    ),
                    supportsOpacity: false
                ) {
                    Text("Color of \(product.displayName)", comment: "Settings, App Colors: what VoiceOver reads for an app's colour well")
                }
                .labelsHidden()
            }
        } label: {
            HStack(spacing: 8) {
                AppIconView(
                    name: product.displayName, swatch: palette.swatch(for: product.name), size: 20,
                    artwork: session.windowStores.icons.artwork(of: product, in: session.buildStore.snapshot)
                )
                Text(product.displayName)
            }
        }
    }
}
