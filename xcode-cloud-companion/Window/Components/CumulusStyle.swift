import SwiftUI

/// The look of the window: "Verre et chronologie" (canvas page 3). Colours are the system's, plus one accent.
enum CumulusStyle {
    /// #5173F7, the app's accent (icon, selected card).
    static let accent = Color(red: 0x51 / 255, green: 0x73 / 255, blue: 0xF7 / 255)
    static let cardRadius: CGFloat = 11
    static let groupRadius: CGFloat = 12
}

extension BuildStatus {
    var tint: Color { Color(nsColor: color) }

    /// The state's colour for words: drawn towards the text's own, so "Succeeded" stays readable on a light card.
    var textTint: Color { tint.mix(with: .primary, by: 0.3) }

    /// The shape drawn in the badge: the state never rests on colour alone.
    var systemImage: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .errored: "exclamationmark"
        case .canceled, .skipped: "minus"
        case .finished: "circle.fill"
        }
    }
}

extension AppSwatch {
    /// Two tones, top to bottom, for the app icons of the sidebar.
    var gradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// A rounded group for related facts, translucent over the tinted window.
    func cumulusGroup() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.background.opacity(0.7), in: .rect(cornerRadius: CumulusStyle.groupRadius))
            .overlay(RoundedRectangle(cornerRadius: CumulusStyle.groupRadius).strokeBorder(.quaternary))
    }
}
