import SwiftUI

/// One card of a chronology: the app's icon, what was built, then how it went and where, and how long it took.
///
/// The rail beside the card carries the state's dot; the card says the state in words, tinted.
struct BuildCard: View {
    let appName: String
    let swatch: AppSwatch
    var artwork: AppArtwork?
    /// A commit's message, a branch's name: what the card is about.
    let title: String
    /// A symbol before the title, for a card that is not a build: the kind of reference.
    var titleSymbol: String?
    /// What stands before the state on the second line: the build's number.
    var prefix: String?
    let status: BuildStatus
    /// The state in words; nil when the title says it already.
    var statusText: String?
    /// What follows the state: the workflow, the branch.
    var facts = ""
    var duration: String?
    var age: String?
    var isSelected = false
    /// A running build's start: its duration is redrawn every second, the rest of the card is not.
    var runningSince: Date?
    var spokenLabel = ""
    var spokenValue = ""

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(name: appName, swatch: swatch, size: 22, artwork: artwork)
                .help(appName)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let titleSymbol {
                        Image(systemName: titleSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                Text(Self.line(prefix: prefix, statusText: statusText, facts: facts, tint: isSelected ? nil : status.textTint))
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                if let runningSince {
                    TickingView(interval: 1) { now in
                        trailing(BuildRowData.clock(max(0, now.timeIntervalSince(runningSince))), isDuration: true)
                    }
                } else if let duration {
                    trailing(duration, isDuration: true)
                }
                if let age {
                    trailing(age, isDuration: false)
                }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityValue(Text(spokenValue))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    private func trailing(_ text: String, isDuration: Bool) -> some View {
        Text(text)
            .font(isDuration ? .system(.caption, design: .monospaced) : .caption2)
            .foregroundStyle(secondary)
    }

    /// “#394 · Failed · 3 tests · Release · main”, the state alone in its colour.
    static func line(prefix: String?, statusText: String?, facts: String, tint: Color?) -> AttributedString {
        var line = AttributedString()
        func append(_ part: AttributedString) {
            if !line.characters.isEmpty {
                line += AttributedString(UsageFormat.dotted(["", ""]))
            }
            line += part
        }
        if let prefix, !prefix.isEmpty {
            var part = AttributedString(prefix)
            part.swiftUI.font = .system(.caption, design: .monospaced)
            append(part)
        }
        if let statusText, !statusText.isEmpty {
            var part = AttributedString(statusText)
            part.swiftUI.font = .caption.weight(.semibold)
            if let tint { part.swiftUI.foregroundColor = tint }
            append(part)
        }
        if !facts.isEmpty {
            append(AttributedString(facts))
        }
        return line
    }
}

extension BuildCard {
    /// A build of the list: its commit's message for a title, or how it went when Apple gave no message.
    init(row: BuildRowData, now: Date, swatch: AppSwatch, artwork: AppArtwork?, isSelected: Bool) {
        let summary = row.summary(now: now)
        self.init(
            appName: row.productName, swatch: swatch, artwork: artwork,
            title: row.commitTitle ?? summary, prefix: row.numberText, status: row.status,
            statusText: row.commitTitle == nil ? nil : summary, facts: row.facts,
            duration: row.duration(now: now), age: row.age(now: now), isSelected: isSelected, runningSince: row.runningSince,
            spokenLabel: [row.commitTitle, row.numberText, summary].compactMap(\.self).joined(separator: ", "),
            spokenValue: row.spokenDetail
        )
    }
}

#Preview("Cartes") {
    VStack(spacing: 8) {
        BuildCard(
            appName: "Crossfit Hyrox Tracker", swatch: .purple, title: "Ajoute le suivi des temps de repos", prefix: "#394", status: .running,
            statusText: "En cours · 4 min", facts: "Public archive · develop", duration: "4:12", age: "4m"
        )
        BuildCard(
            appName: "Crossfit Hyrox Tracker", swatch: .purple, title: "Corrige l’import CSV des semaines passées", prefix: "#393", status: .failed,
            statusText: "Échec · 3 tests", facts: "Public archive · develop", duration: "15:35", age: "2h", isSelected: true
        )
        BuildCard(
            appName: "Cumulus", swatch: .blue, title: "Première version du menu", prefix: "#2", status: .succeeded,
            statusText: "Réussi · TestFlight", facts: "Default · main", duration: "9:44", age: "3d"
        )
        BuildCard(appName: "Cumulus", swatch: .blue, title: "Annulé", prefix: "#385", status: .canceled, facts: "Default · main", age: "5d")
        BuildCard(
            appName: "Cumulus", swatch: .blue, title: "main", titleSymbol: "arrow.triangle.branch", status: .succeeded,
            statusText: "Réussi", facts: "Release · #394", age: "1h"
        )
    }
    .padding(16)
    .frame(width: 372)
}
