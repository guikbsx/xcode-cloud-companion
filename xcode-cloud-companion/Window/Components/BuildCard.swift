import SwiftUI

/// One build of the list: badge, number, a line saying how it went, where it ran, how long it took.
struct BuildCard: View {
    let status: BuildStatus
    let number: String
    let summary: String
    let detail: String
    let duration: String?
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: status, size: 28, isOnAccent: isSelected)
            Text(number)
                .font(.system(.callout, design: .monospaced, weight: .bold))
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let duration {
                Text(duration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isSelected ? AnyShapeStyle(CumulusStyle.accent) : AnyShapeStyle(.background.opacity(0.85)),
            in: .rect(cornerRadius: CumulusStyle.cardRadius)
        )
        .overlay(RoundedRectangle(cornerRadius: CumulusStyle.cardRadius).strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.06)))
        .shadow(color: isSelected ? CumulusStyle.accent.opacity(0.35) : .clear, radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(number), \(status.label), \(summary)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Cartes") {
    VStack(spacing: 8) {
        BuildCard(status: .running, number: "#390", summary: "En cours · 4 min", detail: "realmotivation · Public archive · develop", duration: "15:21")
        BuildCard(status: .failed, number: "#389", summary: "Échec · 3 tests", detail: "realmotivation · Public archive · develop", duration: "6:12", isSelected: true)
        BuildCard(status: .succeeded, number: "#17", summary: "Réussi · TestFlight", detail: "second-brain · Internal TestFlight Build · main", duration: "11:05")
        BuildCard(status: .canceled, number: "#385", summary: "Annulé", detail: "realmotivation · develop", duration: nil)
    }
    .padding(16)
    .frame(width: 372)
}
