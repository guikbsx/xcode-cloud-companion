import SwiftUI

/// An app's icon, or its initial in its palette colour while it has none.
struct AppIconView: View {
    let name: String
    let swatch: AppSwatch
    var size: CGFloat = 22
    var artwork: AppArtwork?

    var body: some View {
        face.accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let artwork {
            // A Mac icon is drawn as it comes; any other is a full square, rounded like on the Home Screen.
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: artwork.isMacIcon ? 0 : size * 0.225, style: .continuous))
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(swatch.gradient, in: .rect(cornerRadius: size * 0.27))
        }
    }
}

/// How a workflow's last build went, as a dot: hollow while it has no build, ringed while one runs.
struct StatusDot: View {
    let status: BuildStatus?
    var size: CGFloat = 8

    var body: some View {
        Group {
            if let status {
                Circle()
                    .fill(status.tint)
                    .overlay {
                        if status == .running {
                            Circle().stroke(status.tint.opacity(0.28), lineWidth: 3).padding(-3)
                        }
                    }
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The cycle at the head of the sidebar: a ring for how much of the plan is used, the minutes, and when it resets.
struct CycleCard: View {
    let fractionUsed: Double
    let usedText: String
    let resetText: String
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.012, min(max(fractionUsed, 0), 1)))
                    .stroke(redaction.isSkeleton ? Color.skeleton : CumulusStyle.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(UsageFormat.compactPercent(fractionUsed))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(usedText).font(.caption.weight(.semibold)).lineLimit(2)
                Text(resetText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Cycle"))
        .accessibilityValue(Text(UsageFormat.dotted([UsageFormat.percent(fractionUsed), usedText, resetText])))
    }
}

/// What the app is doing with Apple, above the cycle: one line most of the time, a card while builds are measured.
struct SyncActivityView: View {
    let activity: SyncActivity
    let now: Date
    /// Named when the card is about another account than the one on screen.
    var accountName: String?

    var body: some View {
        switch activity {
        case .measuring(let progress, let isFirstSync, let step):
            measuring(progress, isFirstSync: isFirstSync, step: step)
        case .syncing(let step):
            line {
                ProgressView().controlSize(.mini)
                Text(step ?? String(localized: "Updating…"))
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            line {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
            }
            .foregroundStyle(.orange)
            .help(message)
        case .idle(let lastSync):
            line {
                Text(Self.updatedText(lastSync: lastSync, now: now))
            }
            .foregroundStyle(.tertiary)
        }
    }

    /// A sync that ended after the clock was last read happened "now", never "in 35 seconds".
    nonisolated static func updatedText(lastSync: Date?, now: Date) -> String {
        guard let lastSync else { return String(localized: "Not updated yet") }
        return String(localized: "Updated \(UsageFormat.relative(lastSync, now: max(now, lastSync)))")
    }

    /// One line of a fixed height, whatever it says: the sidebar does not jump when a sync starts or ends.
    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5) {
            content()
        }
        .font(.caption2)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func measuring(_ progress: MeasurementProgress, isFirstSync: Bool, step: String?) -> some View {
        let hasCount = progress.totalActions > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(UsageFormat.dotted([accountName, isFirstSync ? String(localized: "First sync") : String(localized: "Measuring your builds")].compactMap(\.self)))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasCount {
                    Text("\(progress.measuredActions + progress.unmeasurableActions) / \(progress.totalActions)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            ThinProgressBar(fraction: hasCount ? progress.fractionDone : 0)
            Group {
                if hasCount {
                    Text("Fetching test results · about \(progress.minutesLeft) min left", comment: "Sidebar, while builds are measured: minutes until the usage figures are complete.")
                } else {
                    Text(step ?? String(localized: "Listing your apps and their builds…"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // No `fixedSize` here: see `CyclePromptCard`.
            .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
    }
}

/// In the cycle's place while the plan has no reset date: without it there is no cycle to draw, and the sidebar says so
/// instead of showing nothing.
struct CyclePromptCard: View {
    let setPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cycle").font(.caption).fontWeight(.semibold)
            // No `fixedSize(vertical:)` in the sidebar's foot: asked for its smallest size, the window proposes no width,
            // the text then stands one word a line, and its height becomes the least height of the whole window.
            Text("Set your plan’s reset date to see how much of it is used.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("Set Your Plan…", action: setPlan)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

/// The prominent ▶ of the toolbar, in glass.
struct LaunchButtonLabel: View {
    var title: LocalizedStringKey = "Launch"

    var body: some View {
        Label(title, systemImage: "play.fill")
    }
}

#Preview("Barre latérale") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
            AppIconView(name: "realmotivation", swatch: .blue)
            AppIconView(name: "second-brain", swatch: .yellow)
            StatusDot(status: .running)
            StatusDot(status: .failed)
            StatusDot(status: nil)
        }
        CycleCard(fractionUsed: 0.05, usedText: "1 h 13 min sur 25 h", resetText: "Réinit. le 7 nov.")
        Button(action: {}) { LaunchButtonLabel() }.buttonStyle(.glassProminent)
    }
    .padding(20)
    .frame(width: 240)
}
