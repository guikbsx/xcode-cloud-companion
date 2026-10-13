import SwiftUI

/// The head of the Overview: the cycle as a ring cut by app, what is used and at what pace, and the legend.
struct CycleRingGroup: View {
    let summary: UsageSummary
    let model: OverviewModel
    /// Loaded app icons by product name; unused by the ring, kept for the legend's future.
    var artwork: [String: AppArtwork] = [:]

    private var isMeasuring: Bool { summary.measurement.isMeasuring }

    var body: some View {
        // The ring beside its figures; above them in a column too narrow for both.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                ring
                // An ideal width of its own: the sentences wrap, they do not send the ring above them.
                texts.frame(minWidth: 250, idealWidth: 250, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 14) {
                ring
                texts
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private var ring: some View {
        CycleRing(segments: isMeasuring ? [] : model.ring, remainingTint: remainingTint) {
            VStack(spacing: 2) {
                Text(isMeasuring ? "—" : UsageFormat.compactPercent(summary.writtenFractionUsed))
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("of the plan", comment: "Under the percentage at the centre of the cycle's ring. Two or three words.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
        }
        .frame(width: 120, height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMeasuring ? Text("Measuring usage…") : Text("Cycle used at \(UsageFormat.percent(summary.writtenFractionUsed))"))
        .accessibilityAddTraits(.isImage)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isMeasuring {
                measuring
            } else {
                figures
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        Text("\(UsageFormat.minutes(summary.usedMinutes)) used", comment: "Head of the Overview: the compute time used this cycle")
            .font(.system(size: 22, weight: .bold, design: .rounded))
        VStack(alignment: .leading, spacing: 2) {
            Text("of \(UsageFormat.minutes(summary.quotaMinutes)) · resets \(UsageFormat.day(summary.resetDate)), in \(UsageFormat.timeLeft(summary.timeUntilReset))",
                 comment: "Under the time used: the plan, the reset date, and the time left until it")
            Text(summary.paceLine)
            Text(summary.exportLine)
                .foregroundStyle(summary.isImportStale ? Color.orange : Color.secondary)
            if summary.measurement.unmeasurableBuilds > 0 {
                Text("\(summary.measurement.unmeasurableBuilds) builds not measured, estimated from their duration")
                    .foregroundStyle(Color.orange)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(model.apps) { app in
                legend(app.displayName, value: app.minutesText, fill: AnyShapeStyle(app.swatch.color))
            }
            legend(String(localized: "Remaining", comment: "Legend of the cycle's ring: the part of the plan not used yet"),
                   value: UsageFormat.minutes(summary.availableMinutes), fill: AnyShapeStyle(remainingTint))
        }
        .padding(.top, 2)
        if model.hasEstimates {
            Text("Figures with a ~ are estimates computed from the builds’ durations, not Apple’s billing. Import an export for exact minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var measuring: some View {
        Text("Measuring usage…").font(.system(size: 22, weight: .bold, design: .rounded))
        HStack(alignment: .top, spacing: 18) {
            stat("Measured so far", UsageFormat.compactMinutes(summary.usedMinutes))
            stat("Still to measure", String(localized: "\(summary.measurement.pendingBuilds) builds"))
        }
        Text("The gauge and the menu bar percentage appear once every build of the cycle is measured.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.body.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The name comes first: when it does not fit beside its figures, the figures go under it.
    private func legend(_ name: String, value: String, fill: AnyShapeStyle) -> some View {
        let square = RoundedRectangle(cornerRadius: 2.5).fill(fill).frame(width: 9, height: 9).accessibilityHidden(true)
        let figures = Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                square
                Text(name).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                figures.fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                square
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    figures.minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    /// The track left over warns early, like the menu's gauge: neutral up to 75 %, orange then red.
    private var remainingTint: Color {
        switch summary.fractionUsed {
        case ..<0.75: Color.primary.opacity(0.1)
        case ..<0.9: Color.orange.opacity(0.4)
        default: Color.red.opacity(0.4)
        }
    }
}

/// A ring of arcs over a track, with something at its centre.
struct CycleRing<Center: View>: View {
    let segments: [OverviewModel.RingSegment]
    var remainingTint = Color.primary.opacity(0.1)
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(remainingTint, lineWidth: lineWidth)
            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.swatch.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(lineWidth / 2)
    }
}

/// The workflows' shares of the cycle, as one bar above their lines.
struct WorkflowBar: View {
    let segments: [OverviewModel.WorkflowSegment]

    var body: some View {
        GeometryReader { proxy in
            let spacing = 2.0
            let width = max(0, proxy.size.width - spacing * Double(max(segments.count - 1, 0)))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.swatch.map { AnyShapeStyle($0.color.opacity(segment.shade)) } ?? AnyShapeStyle(Color.primary.opacity(0.15)))
                        .frame(width: max(2, width * segment.fraction))
                }
            }
        }
        .frame(height: 14)
        .clipShape(.rect(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
