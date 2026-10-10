import SwiftUI

/// A small rounded label: state, branch, commit.
struct CapsuleTag: View {
    let text: String
    var systemImage: String?
    var tint: Color?
    var isMonospaced = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(.caption, design: isMonospaced ? .monospaced : .default, weight: isMonospaced ? .medium : .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(tint ?? Color.primary)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.15), in: .capsule)
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                VStack(spacing: 6) {
                    node(for: step)
                    Text(step.name).font(.caption.weight(.semibold))
                    Text(step.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(width: 120)
                .opacity(step.status == .skipped ? 0.5 : 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(step.name), \(step.status.label), \(step.detail)"))
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(step.status == .succeeded ? AnyShapeStyle(BuildStatus.succeeded.tint) : AnyShapeStyle(Color.primary.opacity(0.14)))
                        .frame(height: 2)
                        .padding(.top, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
