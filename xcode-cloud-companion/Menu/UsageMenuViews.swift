import SwiftUI

/// Width a SwiftUI block of the status menu is measured at; the menu then stretches it to its own width.
let usageMenuContentWidth: CGFloat = 300

extension AppSwatch {
    var color: Color { Color(nsColor) }
}

/// The cycle gauge: one bar cut by app, with what is used, what is left and how sure the figures are.
struct UsageGaugeView: View {
    let summary: UsageSummary
    let palette: AppPalette
    /// Store names by product name, for what VoiceOver reads; the colours stay keyed by the product.
    var displayNames: [String: String] = [:]

    private var isMeasuring: Bool { summary.measurement.isMeasuring }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(isMeasuring
                    ? String(localized: "Measuring usage…")
                    : String(localized: "\(UsageFormat.percent(summary.writtenFractionUsed)) of \(UsageFormat.minutes(summary.quotaMinutes)) used"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Resets \(UsageFormat.moment(summary.resetDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            SegmentedUsageBar(segments: summary.gaugeSegments, quotaMinutes: summary.quotaMinutes, palette: palette, remainingTint: remainingTint, displayNames: displayNames)
                .opacity(isMeasuring ? 0.45 : 1)
            if isMeasuring {
                HStack(alignment: .top, spacing: 12) {
                    stat("Measured so far", UsageFormat.compactMinutes(summary.usedMinutes))
                    stat("Available", "—")
                    stillToMeasureStat.fixedSize(horizontal: true, vertical: false)
                }
                .opacity(0.45)
                Text("The gauge and the menu bar percentage appear once every build of the cycle is measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    stat("Used", UsageFormat.compactMinutes(summary.usedMinutes))
                    stat("Available", UsageFormat.compactMinutes(summary.availableMinutes))
                    estimatedStat.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.paceLine)
                        .foregroundStyle(.secondary)
                    Text(summary.exportLine)
                        .foregroundStyle(.secondary)
                    if summary.measurement.unmeasurableBuilds > 0 {
                        Text("\(summary.measurement.unmeasurableBuilds) builds not measured, estimated from their duration")
                            .foregroundStyle(Color.orange)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: usageMenuContentWidth, idealWidth: usageMenuContentWidth, maxWidth: .infinity, alignment: .leading)
    }

    /// The track left over warns early: neutral up to 75 %, orange then red.
    private var remainingTint: Color {
        switch summary.fractionUsed {
        case ..<0.75: Color.primary.opacity(0.1)
        case ..<0.9: Color.orange.opacity(0.4)
        default: Color.red.opacity(0.4)
        }
    }

    private var stillToMeasureStat: some View {
        stat("Still to measure", String(localized: "\(summary.measurement.pendingBuilds) builds"))
    }

    private var estimatedStat: some View {
        let count = summary.estimatedBuildCount
        return stat(
            count > 0 ? "Estimated · \(count) builds" : "Estimated",
            count > 0 ? "~" + UsageFormat.compactMinutes(summary.estimatedMinutes) : "—"
        )
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the cycle's figures say in words: one wording for the menu's gauge and the window's Overview.
nonisolated extension UsageSummary {
    var paceLine: String {
        if let exhaustion = exhaustionDate {
            if exhaustion <= now {
                return String(localized: "Plan used up · resets \(UsageFormat.moment(resetDate))")
            }
            if resetDate.timeIntervalSince(exhaustion) < 24 * 3600 {
                return String(localized: "Just lasts until the reset at this pace")
            }
            return String(localized: "Runs out around \(UsageFormat.day(exhaustion)) at this pace")
        }
        if projectedMinutes != nil {
            return String(localized: "Lasts until the reset at this pace")
        }
        return String(localized: "Too early in the cycle to project a pace")
    }

    var exportLine: String {
        guard let lastImport else {
            return String(localized: "No usage export yet: figures are estimates")
        }
        return String(localized: "Export \(UsageFormat.relative(lastImport, now: now))")
    }
}

/// Shown above everything while the first test results are being fetched: what is going on, how far, how long.
struct MeasuringHeaderView: View {
    let progress: MeasurementProgress
    var isFirstSync = false
    /// What the synchronizer is doing, shown until there are test results to count.
    var activity: String?

    /// Before the builds are listed there is nothing to count yet.
    private var hasCount: Bool { progress.totalActions > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(isFirstSync ? String(localized: "First sync · measuring your builds") : String(localized: "Measuring your builds"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if hasCount {
                    Text("\(progress.measuredActions + progress.unmeasurableActions) / \(progress.totalActions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ThinProgressBar(fraction: hasCount ? progress.fractionDone : 0)
            Group {
                if hasCount {
                    Text("Fetching test results, \(MeasurementProgress.actionsPerPass) builds at a time · about \(progress.minutesLeft) min left. Figures fill in as they arrive; you can close this menu.")
                } else {
                    Text(activity ?? String(localized: "Listing your apps and their builds…"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: usageMenuContentWidth, idealWidth: usageMenuContentWidth, maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel(Text("Measuring progress"))
            .accessibilityValue(Text(UsageFormat.percent(fraction)))
    }
}

/// Drawn rather than a `ProgressView`, which turns grey when the menu's window is not key.
struct SegmentedUsageBar: View {
    let segments: [GaugeSegment]
    let quotaMinutes: Double
    let palette: AppPalette
    let remainingTint: Color
    var displayNames: [String: String] = [:]

    var body: some View {
        GeometryReader { proxy in
            let widths = GaugeLayout.widths(minutes: segments.map(\.minutes), quotaMinutes: quotaMinutes, totalWidth: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Rectangle()
                        .fill(color(for: segment))
                        .frame(width: widths[index])
                }
                Rectangle().fill(remainingTint)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(Text("Usage by app"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private func color(for segment: GaugeSegment) -> Color {
        guard let product = segment.product else { return Color.primary.opacity(0.3) }
        return palette.swatch(for: product).color
    }

    private var accessibilityValue: String {
        segments.map { segment in
            let name = segment.product.map { displayNames[$0] ?? $0 } ?? String(localized: "Estimated")
            return "\(name) \(UsageFormat.minutes(segment.minutes))"
        }
        .formatted(.list(type: .and))
    }
}
