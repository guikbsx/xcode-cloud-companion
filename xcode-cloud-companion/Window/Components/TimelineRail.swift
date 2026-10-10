import SwiftUI

/// A day heading of the chronology ("Aujourd'hui", "Hier", "Cette semaine"…).
struct DayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 46)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of the chronology: the state's dot on a vertical rail, then the content.
struct TimelineRow<Content: View>: View {
    let status: BuildStatus
    var isFirst = false
    var isLast = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Color.primary.opacity(0.1)).frame(width: 2, height: 20)
                Circle()
                    .fill(status.tint)
                    .frame(width: 12, height: 12)
                    .overlay {
                        if status == .running {
                            Circle().stroke(status.tint.opacity(0.28), lineWidth: 3).padding(-3)
                        }
                    }
                Rectangle().fill(isLast ? .clear : Color.primary.opacity(0.1)).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 22)
            .accessibilityHidden(true)
            content
                .padding(.vertical, 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
    }
}

#Preview("Chronologie") {
    VStack(spacing: 0) {
        DayHeader(title: "Aujourd'hui")
        TimelineRow(status: .running, isFirst: true) {
            BuildCard(status: .running, number: "#390", summary: "En cours · 4 min", detail: "realmotivation · develop", duration: "15:21")
        }
        DayHeader(title: "Hier")
        TimelineRow(status: .failed) {
            BuildCard(status: .failed, number: "#389", summary: "Échec · 3 tests", detail: "realmotivation · develop", duration: "6:12", isSelected: true)
        }
        TimelineRow(status: .succeeded, isLast: true) {
            BuildCard(status: .succeeded, number: "#386", summary: "Réussi · TestFlight", detail: "realmotivation · develop", duration: "14:20")
        }
    }
    .frame(width: 372)
    .padding(.vertical, 8)
}
