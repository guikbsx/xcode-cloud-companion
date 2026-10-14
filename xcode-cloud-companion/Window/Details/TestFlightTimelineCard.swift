import SwiftUI

/// “From the commit to the testers”: the steps a build went through to reach TestFlight, with the times that are
/// known. A time is Apple's, or it is said as the time Cumulus saw the step; a step that cannot be told is left out.
struct TestFlightTimelineCard: View {
    let timeline: TestFlightTimeline
    /// “1.4 (412)”.
    let buildLabel: String

    private static let narrowestStep: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("From the commit to the testers")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .unredacted()
                Text("Build \(buildLabel)")
                    .fontWeight(.semibold)
            }
            ViewThatFits(in: .horizontal) {
                ForEach(ActionsFrieze.rowSizes(for: timeline.steps.count), id: \.self) { perRow in
                    rows(of: perRow)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private func rows(of perRow: Int) -> some View {
        VStack(spacing: 14) {
            ForEach(Array(stride(from: 0, to: timeline.steps.count, by: perRow)), id: \.self) { start in
                let row = Array(timeline.steps[start..<min(start + perRow, timeline.steps.count)])
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, step in
                        stepView(step)
                        if index < row.count - 1 {
                            Rectangle()
                                .fill(step.state == .done && row[index + 1].state == .done ? AnyShapeStyle(BuildStatus.succeeded.tint) : AnyShapeStyle(Color.primary.opacity(0.14)))
                                .frame(minWidth: 8, idealWidth: 8, maxWidth: .infinity)
                                .frame(height: 2)
                                .padding(.top, 12)
                        }
                    }
                }
            }
        }
    }

    private func stepView(_ step: TestFlightTimeline.Step) -> some View {
        VStack(spacing: 6) {
            node(for: step.state)
            Text(step.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            if let detail = step.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: Self.narrowestStep, idealWidth: Self.narrowestStep, maxWidth: 130)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(step)))
    }

    private func node(for state: TestFlightTimeline.State) -> some View {
        let (image, tint): (String, Color) = switch state {
        case .done: ("checkmark", BuildStatus.succeeded.tint)
        case .current: ("clock", BuildStatus.running.tint)
        case .upcoming: ("circle", Color.secondary)
        case .failed: ("xmark", BuildStatus.failed.tint)
        case .ended: ("minus", Color.secondary)
        }
        return Image(systemName: image)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(.background, in: .circle)
            .overlay(Circle().strokeBorder(tint.opacity(state == .upcoming ? 0.6 : 0.3), lineWidth: state == .upcoming ? 1.5 : 1))
    }

    /// The state in words for VoiceOver, since a node is only a shape.
    static func spoken(_ step: TestFlightTimeline.Step) -> String {
        let state = switch step.state {
        case .done: String(localized: "done", comment: "VoiceOver: a step of the TestFlight timeline that happened")
        case .current: String(localized: "under way", comment: "VoiceOver: a step of the TestFlight timeline that is happening")
        case .upcoming: String(localized: "not yet", comment: "VoiceOver: a step of the TestFlight timeline that has not happened yet")
        case .failed: String(localized: "did not succeed", comment: "VoiceOver: a step of the TestFlight timeline that failed")
        case .ended: String(localized: "ended", comment: "VoiceOver: a step of the TestFlight timeline that is over because the build expired")
        }
        return UsageFormat.dotted([step.name, state, step.detail].compactMap(\.self))
    }
}
