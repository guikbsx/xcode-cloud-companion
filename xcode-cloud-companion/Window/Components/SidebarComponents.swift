import SwiftUI

/// An app's icon, or its initial in its palette colour while it has none, with the state of its last build when known.
struct AppIconView: View {
    let name: String
    let swatch: AppSwatch
    var lastStatus: BuildStatus?
    var size: CGFloat = 22
    var artwork: AppArtwork?

    var body: some View {
        face
            .overlay(alignment: .bottomTrailing) {
                if let lastStatus {
                    Circle()
                        .fill(lastStatus.tint)
                        .frame(width: size * 0.46, height: size * 0.46)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let artwork {
            // A Mac icon is drawn as it comes; any other is a full square, rounded like on the Home Screen.
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: artwork.isMacIcon ? 0 : size * 0.225, style: .continuous))
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(swatch.gradient, in: .rect(cornerRadius: size * 0.27))
        }
    }
}

/// The cycle at the foot of the sidebar: how much of the plan is used, and when it resets.
struct CycleCard: View {
    let fractionUsed: Double
    let usedText: String
    let resetText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cycle · \(UsageFormat.compactPercent(fractionUsed))").fontWeight(.semibold)
                Spacer()
                Text(resetText).foregroundStyle(.secondary)
            }
            .font(.caption)
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(CumulusStyle.accent).frame(width: max(4, proxy.size.width * min(max(fractionUsed, 0), 1)))
                    }
                }
            Text(usedText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(UsageFormat.percent(fractionUsed)))
    }
}

/// The prominent ▶ of the toolbar, in glass.
struct LaunchButtonLabel: View {
    var title: LocalizedStringKey = "Launch"

    var body: some View {
        Label(title, systemImage: "play.fill")
    }
}

#Preview("Barre latérale") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
            AppIconView(name: "realmotivation", swatch: .blue, lastStatus: .running)
            AppIconView(name: "second-brain", swatch: .yellow, lastStatus: .succeeded)
            AppIconView(name: "cycletracker", swatch: .cyan, lastStatus: .failed)
        }
        CycleCard(fractionUsed: 0.02, usedText: "23 min sur 25 h", resetText: "réinit. 7 nov.")
        Button(action: {}) { LaunchButtonLabel() }.buttonStyle(.glassProminent)
    }
    .padding(20)
    .frame(width: 240)
}
