import SwiftUI

/// Where an app's overview would be, without Pro: the whole column says what the screen shows and leads to the
/// purchase sheet. It reads nothing about the app beyond its name and its icon.
struct AppOverviewLockedPage: View {
    let appName: String
    let swatch: AppSwatch
    var artwork: AppArtwork?
    @Environment(ProAccess.self) private var access: ProAccess?

    private struct Highlight: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private var highlights: [Highlight] {
        [
            Highlight(
                id: "square.stack.3d.up", title: String(localized: "Every workflow"),
                detail: String(localized: "Its last build, its success rate, its median duration and its minutes this cycle.")
            ),
            Highlight(
                id: "chart.bar.xaxis", title: String(localized: "The last 30 builds"),
                detail: String(localized: "Their durations side by side, failures in red, and the time spent in the queue.")
            ),
            Highlight(
                id: "gauge.with.dots.needle.33percent", title: String(localized: "The app’s share of the cycle"),
                detail: String(localized: "What this app used of the plan, workflow by workflow, and where it is heading.")
            ),
            Highlight(
                id: "arrow.triangle.branch", title: String(localized: "Branches and pull requests"),
                detail: String(localized: "The last build of each, and the one that cost the most.")
            ),
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // Two cards side by side once each has room for its sentence on two or three lines.
                content(twoColumns: proxy.size.width >= 560)
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private func content(twoColumns: Bool) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                AppIconView(name: appName, swatch: swatch, size: 76, artwork: artwork)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.tint, in: .circle)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                            .offset(x: 7, y: 7)
                            .accessibilityHidden(true)
                    }
                    .padding(.bottom, 6)
                Text("Cumulus Pro")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                Text("\(appName) at a glance", comment: "Title of the locked app overview. The placeholder is an app’s name.")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("One screen for this app: its workflows, its cycle, its last builds and its branches.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if twoColumns {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            card(highlights[0])
                            card(highlights[1])
                        }
                        GridRow {
                            card(highlights[2])
                            card(highlights[3])
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(highlights) { card($0) }
                    }
                }
            }
            // The cards of a row share a height; none grows to fill the page.
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button {
                    access?.showPurchase(for: .appOverview)
                } label: {
                    Text("Discover Pro")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("The builds of this app stay in the list, with or without Pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ highlight: Highlight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: highlight.id)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .fontWeight(.semibold)
                Text(highlight.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cumulusGroup()
        .accessibilityElement(children: .combine)
    }
}
