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
///
/// The dot is a symbol so that it can breathe while its build runs.
struct TimelineRow<Content: View>: View {
    let status: BuildStatus
    var isFirst = false
    var isLast = false
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Color.primary.opacity(0.1)).frame(width: 2, height: 20)
                Image(systemName: "circle.fill")
                    .resizable()
                    .foregroundStyle(status.tint)
                    .frame(width: 12, height: 12)
                    .symbolEffect(.breathe, options: .repeat(.continuous), isActive: breathes)
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

    private var breathes: Bool {
        status == .running && !reduceMotion
    }
}

#Preview("Chronologie") {
    VStack(spacing: 0) {
        DayHeader(title: "Aujourd'hui")
        TimelineRow(status: .running, isFirst: true) {
            BuildCard(appName: "realmotivation", swatch: .blue, title: "Ajoute le suivi des temps de repos", prefix: "#390", status: .running, statusText: "En cours · 4 min", facts: "develop", duration: "15:21")
        }
        DayHeader(title: "Hier")
        TimelineRow(status: .failed) {
            BuildCard(appName: "realmotivation", swatch: .blue, title: "Corrige l’import CSV", prefix: "#389", status: .failed, statusText: "Échec · 3 tests", facts: "develop", duration: "6:12", isSelected: true)
        }
        TimelineRow(status: .succeeded, isLast: true) {
            BuildCard(appName: "realmotivation", swatch: .blue, title: "Prépare la 1.3", prefix: "#386", status: .succeeded, statusText: "Réussi · TestFlight", facts: "develop", duration: "14:20")
        }
    }
    .frame(width: 372)
    .padding(.vertical, 8)
}
