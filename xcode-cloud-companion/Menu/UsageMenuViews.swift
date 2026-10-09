import Charts
import SwiftUI

/// Width shared by every SwiftUI block hosted in the status menu.
let usageMenuContentWidth: CGFloat = 300

struct UsageHeaderView: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(UsageFormat.percent(summary.fractionUsed)) used")
                    .font(.headline)
                Spacer()
                Text("Resets in \(UsageFormat.timeLeft(summary.timeUntilReset))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            UsageBar(fraction: summary.fractionUsed, tint: tint)
            Text(paceLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(sourceLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if summary.isImportStale {
                Label(staleLine, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: usageMenuContentWidth, alignment: .leading)
    }

    private var tint: Color {
        switch summary.fractionUsed {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }

    private var paceLine: String {
        if let exhaustion = summary.exhaustionDate {
            if exhaustion <= summary.now {
                return String(localized: "Plan used up · resets \(UsageFormat.moment(summary.resetDate))")
            }
            if summary.resetDate.timeIntervalSince(exhaustion) < 24 * 3600 {
                return String(localized: "Just lasts until the reset at this pace")
            }
            return String(localized: "Runs out around \(UsageFormat.day(exhaustion)) at this pace")
        }
        if summary.projectedMinutes != nil {
            return String(localized: "Lasts until the reset at this pace · \(UsageFormat.moment(summary.resetDate))")
        }
        return String(localized: "Resets \(UsageFormat.moment(summary.resetDate))")
    }

    private var sourceLine: String {
        let billed = UsageFormat.minutes(summary.billedMinutes)
        guard summary.estimatedBuildCount > 0 else {
            return String(localized: "\(billed) billed by Apple")
        }
        let estimated = UsageFormat.minutes(summary.estimatedMinutes)
        return String(localized: "\(billed) billed by Apple + ~\(estimated) estimated for \(summary.estimatedBuildCount) recent builds")
    }

    private var staleLine: String {
        guard let lastImport = summary.lastImport else {
            return String(localized: "No usage export yet: figures are estimates")
        }
        return String(localized: "Last usage export \(UsageFormat.relative(lastImport, now: summary.now))")
    }
}

/// Drawn rather than a `ProgressView`, which turns grey when the menu's window is not key.
struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityValue(Text(UsageFormat.percent(fraction)))
    }
}

struct UsageStatsView: View {
    let summary: UsageSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                stat("Used", UsageFormat.minutes(summary.usedMinutes))
                stat("Available", UsageFormat.minutes(summary.availableMinutes))
            }
            GridRow {
                stat("Today", UsageFormat.minutes(summary.todayMinutes))
                stat("Last 30 days", UsageFormat.minutes(summary.last30DaysMinutes))
            }
            GridRow {
                stat("Builds, 30 days", summary.buildsLast30Days.formatted())
                stat("Plan", UsageFormat.minutes(summary.quotaMinutes))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: usageMenuContentWidth, alignment: .leading)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageHistogramView: View {
    let daily: [DailyUsage]

    var body: some View {
        Chart {
            ForEach(daily, id: \.day) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.billedMinutes))
                    .foregroundStyle(by: .value("Source", String(localized: "Billed")))
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.estimatedMinutes))
                    .foregroundStyle(by: .value("Source", String(localized: "Estimated")))
            }
        }
        .chartForegroundStyleScale([
            String(localized: "Billed"): Color.accentColor,
            String(localized: "Estimated"): Color.accentColor.opacity(0.4),
        ])
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .accessibilityLabel(Text("Usage per day, last 30 days"))
        .frame(height: 64)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: usageMenuContentWidth)
    }
}
