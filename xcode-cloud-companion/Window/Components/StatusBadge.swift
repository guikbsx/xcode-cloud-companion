import SwiftUI

/// A round tinted badge with the state's shape; filled white on the selected card.
struct StatusBadge: View {
    let status: BuildStatus
    var size: CGFloat = 30
    var isOnAccent = false

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: size * (status == .finished ? 0.3 : 0.46), weight: .bold))
            .foregroundStyle(isOnAccent ? AnyShapeStyle(.white) : AnyShapeStyle(status.tint))
            .frame(width: size, height: size)
            .background(isOnAccent ? Color.white.opacity(0.22) : status.tint.opacity(0.16), in: .circle)
            .overlay {
                if status == .running {
                    Circle().stroke(status.tint.opacity(0.28), lineWidth: 3).padding(-3)
                }
            }
            .accessibilityLabel(status.label)
    }
}

#Preview("Statuts") {
    HStack(spacing: 14) {
        ForEach([BuildStatus.running, .succeeded, .failed, .errored, .canceled, .skipped, .finished], id: \.self) { status in
            StatusBadge(status: status)
        }
        StatusBadge(status: .failed, isOnAccent: true)
            .padding(6)
            .background(CumulusStyle.accent, in: .rect(cornerRadius: 10))
    }
    .padding(24)
}
