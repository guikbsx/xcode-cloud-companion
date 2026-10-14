import SwiftUI

/// Above a build that ended in error while Apple reported an incident on Xcode Cloud. Cumulus's words and the times,
/// never Apple's text. It exists only when the page said so: there is no counterpart that says all is well.
struct AppleStatusBanner: View {
    let banner: AppleStatusFormat.Banner
    /// Only an incident still going on can be waited for.
    let canWatch: Bool
    let isWatching: Bool
    let openStatusPage: () -> Void
    let watch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(BuildStatus.errored.textTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(banner.title).fontWeight(.semibold)
                Text(banner.detail).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(BuildStatus.errored.tint.opacity(0.12), in: .rect(cornerRadius: CumulusStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: CumulusStyle.cardRadius).strokeBorder(BuildStatus.errored.tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        Button("View Status Page", action: openStatusPage)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        if isWatching {
            Label("Cumulus will notify you when it’s back", systemImage: "bell")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        } else if canWatch {
            Button("Notify Me When It’s Back", action: watch)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cumulus reads Apple’s status page again every 5 minutes, for up to 12 hours, while it is open. Nothing is relaunched.")
        }
    }
}
