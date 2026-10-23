import SwiftUI

/// The content of the popover of a square: one day of one workflow. It only draws an `OverviewDayDetail`.
struct OverviewDayBubbleView: View {
    static let width: CGFloat = 316

    let detail: OverviewDayDetail
    let swatch: AppSwatch
    var artwork: AppArtwork?
    let words: OverviewDayWords
    var openBuild: (String) -> Void = { _ in }
    var showDay: () -> Void = {}
    /// The pointer is on the bubble or has left it: the bubble opened by a hover stays while it is on it.
    var hoverChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(words.summary(detail.cell))
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 3)
                .accessibilityHidden(true)
            if !detail.lines.isEmpty {
                lines
                    .padding(.top, 9)
            }
            if !detail.isEmpty {
                footer
                    .padding(.top, 11)
            }
        }
        .font(.system(size: 12))
        .padding(.top, 13)
        .padding(.horizontal, 15)
        .padding(.bottom, 12)
        .frame(width: Self.width, alignment: .leading)
        .onHover(perform: hoverChanged)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(words.longDay(detail.day))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                AppIconView(name: detail.appName, swatch: swatch, size: 13, artwork: artwork)
                Text(words.workflowLine(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.spokenHeader(detail))
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(detail.lines) { line in
                lineView(line)
            }
            if detail.hiddenCount > 0 {
                Text(words.andMore(detail.hiddenCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: OverviewDayDetail.Line) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            OverviewBuildDot(line: line)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(words.line(line))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let insight = detail.insight, insight.runID == line.runID {
                    Text(words.insight(insight.text))
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        if detail.lines.count > 1 {
            Button {
                openBuild(line.runID)
            } label: {
                content.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open build")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.spokenLine(line))
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(words.spokenLine(line))
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if let runID = detail.openRunID {
                Button { openBuild(runID) } label: { link(words.openLabel(number: detail.openNumber)) }
                    .buttonStyle(.plain)
            }
            Button(action: showDay) { link(words.seeDayLabel()) }
                .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.top, 9)
        .overlay(alignment: .top) { Rectangle().fill(OverviewColors.rule).frame(height: 1) }
    }

    private func link(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CumulusStyle.accent)
            .underline(true, pattern: .solid)
            .contentShape(.rect)
    }
}

/// The dot of a build line: filled for a verdict, a ring for a build in the queue.
private struct OverviewBuildDot: View {
    let line: OverviewDayDetail.Line

    var body: some View {
        Group {
            switch line.state {
            case .queued:
                Circle().strokeBorder(line.status.tint, lineWidth: 1.6).frame(width: 8, height: 8)
            case .running, .finished:
                Circle().fill(line.status.tint).frame(width: 8, height: 8)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// What a popover looks like, for the bubble drawn inline (a test): a rounded sheet with an arrow towards the square.
struct OverviewBubbleChrome<Content: View>: View {
    let arrowX: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.14))
                }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 12, height: 12)
                    .overlay(alignment: .topLeading) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 12))
                            path.addLine(to: CGPoint(x: 0, y: 0))
                            path.addLine(to: CGPoint(x: 12, y: 0))
                        }
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                    .rotationEffect(.degrees(45))
                    .offset(x: arrowX - 6, y: -6)
            }
    }
}
