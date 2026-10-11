import SwiftUI

/// One build of the list: badge, number, a line saying how it went, where it ran, how long it took.
struct BuildCard: View {
    let status: BuildStatus
    let number: String
    let summary: String
    let detail: String
    let duration: String?
    var isSelected = false
    /// A running build's start: its duration is redrawn every second, the rest of the card is not.
    var runningSince: Date?
    /// What VoiceOver reads for `detail` when the row shortens it: the app's full name, the workflow, the branch.
    var spokenDetail: String?

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
            if let runningSince {
                TickingView(interval: 1) { now in
                    durationText(BuildRowData.clock(max(0, now.timeIntervalSince(runningSince))))
                }
            } else if let duration {
                durationText(duration)
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
        .accessibilityValue(Text(spokenDetail ?? detail))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func durationText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }
}

#Preview("Cartes") {
    VStack(spacing: 8) {
        BuildCard(status: .running, number: "#390", summary: "En cours · 4 min", detail: "realmotivation · Public archive · develop", duration: "15:21")
        BuildCard(status: .failed, number: "#389", summary: "Échec · 3 tests", detail: "realmotivation · Public archive · develop", duration: "6:12", isSelected: true)
        BuildCard(status: .succeeded, number: "#17", summary: "Réussi · TestFlight", detail: "second-brain · Internal TestFlight Build · main", duration: "11:05")
        BuildCard(status: .canceled, number: "#385", summary: "Annulé", detail: "realmotivation · develop", duration: nil)
        BuildCard(status: .failed, number: "#386", summary: "Échec", detail: "Crossfit Hyro… · Public archive (with test) · develop", duration: "1:57")
    }
    .padding(16)
    .frame(width: 372)
}
