import SwiftUI

/// A small rounded label: state, branch, commit.
struct CapsuleTag: View {
    let text: String
    var systemImage: String?
    var tint: Color?
    var isMonospaced = false
    @Environment(\.redactionReasons) private var redaction

    /// In a skeleton a state's colour would say a state: the capsule goes neutral.
    private var shownTint: Color? { redaction.isSkeleton ? nil : tint }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(.caption, design: isMonospaced ? .monospaced : .default, weight: isMonospaced ? .medium : .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(shownTint ?? Color.primary)
        .background((shownTint ?? Color.primary).opacity(shownTint == nil ? 0.07 : 0.15), in: .capsule)
    }
}

/// A tab drawn as a pill: the one on screen is filled with the text's colour, the others are quiet capsules.
struct PillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            // The counter of a pill follows the pill's own ink.
            .tint(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .background(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.07)), in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}

/// A fact with its small-caps key, as in the build and workflow sheets.
struct InfoItem: View {
    let key: String
    let value: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            Text(value)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(help ?? "")
    }
}

/// One step of the actions frieze (Build → Test → Archive).
nonisolated struct FriezeStep: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let status: BuildStatus
}

/// The actions of a build as connected nodes, each with its state and its time.
struct ActionsFrieze: View {
    let steps: [FriezeStep]
    /// Steps that failed and can show their logs, with what the button does; a step being fetched shows a spinner instead.
    var logSteps: Set<String> = []
    var busyLogSteps: Set<String> = []
    var openLogs: (String) -> Void = { _ in }

    /// A step is 120 points wide when there is room and no less than this.
    private static let narrowestStep: CGFloat = 84

    var body: some View {
        // All the steps on one row, tightened if need be; then on as many rows as it takes to fit the column.
        ViewThatFits(in: .horizontal) {
            ForEach(Self.rowSizes(for: steps.count), id: \.self) { perRow in
                rows(of: perRow)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// How many steps a row may hold, from all of them down to one: each is tried until the frieze fits.
    nonisolated static func rowSizes(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var sizes: [Int] = []
        for rows in 1...count {
            let perRow = (count + rows - 1) / rows
            if sizes.last != perRow { sizes.append(perRow) }
        }
        return sizes
    }

    private func rows(of perRow: Int) -> some View {
        VStack(spacing: 14) {
            ForEach(Array(stride(from: 0, to: steps.count, by: perRow)), id: \.self) { start in
                let row = Array(steps[start..<min(start + perRow, steps.count)])
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, step in
                        stepView(step)
                        if index < row.count - 1 {
                            Rectangle()
                                .fill(step.status == .succeeded ? AnyShapeStyle(BuildStatus.succeeded.tint) : AnyShapeStyle(Color.primary.opacity(0.14)))
                                .frame(minWidth: 8, idealWidth: 8, maxWidth: .infinity)
                                .frame(height: 2)
                                .padding(.top, 16)
                        }
                    }
                }
            }
        }
    }

    private func stepView(_ step: FriezeStep) -> some View {
        VStack(spacing: 6) {
            node(for: step)
            Text(step.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            Text(step.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if busyLogSteps.contains(step.id) {
                ProgressView().controlSize(.small)
            } else if logSteps.contains(step.id) {
                Button("Logs") { openLogs(step.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Download this action’s logs and open them in the Finder")
            }
        }
        .frame(minWidth: Self.narrowestStep, idealWidth: Self.narrowestStep, maxWidth: 120)
        // The steps take their full width before the lines between them stretch.
        .layoutPriority(1)
        .opacity(step.status == .skipped ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(step.name), \(step.status.label), \(step.detail)"))
    }

    private func node(for step: FriezeStep) -> some View {
        Image(systemName: step.status.systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(step.status.tint)
            .frame(width: 34, height: 34)
            .background(.background, in: .circle)
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            .overlay {
                if step.status == .failed || step.status == .errored {
                    Circle().stroke(step.status.tint.opacity(0.25), lineWidth: 3).padding(-3)
                }
            }
    }
}

#Preview("Fiche") {
    VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 6) {
            CapsuleTag(text: "Échec", systemImage: "xmark", tint: BuildStatus.failed.tint)
            CapsuleTag(text: "develop", systemImage: "arrow.triangle.branch")
            CapsuleTag(text: "d4c3b2a1", isMonospaced: true)
        }
        ActionsFrieze(steps: [
            FriezeStep(id: "1", name: "Build · iOS", detail: "2 min 40 s", status: .succeeded),
            FriezeStep(id: "2", name: "Test · iOS", detail: "3 min 20 s · 3 échecs", status: .failed),
            FriezeStep(id: "3", name: "Archive · iOS", detail: "ignorée", status: .skipped),
        ])
        .cumulusGroup()
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                InfoItem(key: "Start condition", value: "Modification de branche")
                InfoItem(key: "Started", value: "8 oct. à 15:02")
                InfoItem(key: "Queued for", value: "32 s")
            }
        }
        .cumulusGroup()
    }
    .padding(20)
    .frame(width: 640)
}
