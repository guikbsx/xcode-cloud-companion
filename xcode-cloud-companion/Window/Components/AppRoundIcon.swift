import SwiftUI

extension AppArtwork {
    /// A Mac icon keeps about a tenth of its canvas as transparent margin on each side; enlarged by this much, the circle cut
    /// out of it falls inside the icon and not in its margins.
    static let macIconZoom: CGFloat = 1.26
}

/// An app's icon cut to a circle, like the faces of the Apple Watch; the app's coloured disc with its initial while it has none.
struct AppRoundIcon: View {
    let name: String
    let swatch: AppSwatch
    var artwork: AppArtwork?
    let diameter: CGFloat

    var body: some View {
        face
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let artwork {
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .scaleEffect(artwork.isMacIcon ? AppArtwork.macIconZoom : 1)
                .clipShape(.circle)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5) }
        } else {
            Circle().fill(swatch.gradient)
                .overlay(
                    Text(verbatim: String(name.prefix(1)).uppercased())
                        .font(.system(size: diameter * 0.49, weight: .semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                )
        }
    }
}
