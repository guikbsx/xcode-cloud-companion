import SwiftUI

/// What runs, at the head of the build list, as a card under a heading of its own: one ring with three lines for a single
/// build, nested rings with a legend for two or three (the ones that end first). The card's fill takes the app's colour, or
/// none when the builds are of several apps; it is flat, without glow. Redrawn every ten seconds and at every sync, never per frame.
struct RunningBlockView: View {
    let ids: [String]
    let more: Int
    let snapshot: BuildSnapshot
    var palette = AppPalette()
    /// The apps' icons by product ID; the legend uses them when the builds are of several apps.
    var artwork: [String: AppArtwork] = [:]
    let selectedID: String?
    let select: (String) -> Void
    /// Shows only the running builds; nil leaves the line “and 2 more running” out.
    var showMore: (() -> Void)?

    static let singleSize: CGFloat = 64
    static let nestedSize: CGFloat = 96
    static let nestedLineWidth: CGFloat = 8
    /// Below this width the legend goes under the rings.
    static let sideBySideWidth: CGFloat = 300
    static let padding: CGFloat = 14
    /// From the card's edge to its heading, so that the heading lines up with the day headings of the list.
    static let headingInset: CGFloat = 7

    @State private var width: CGFloat = 340
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? CumulusStyle.accent.mix(with: .white, by: 0.2) : CumulusStyle.accent
    }

    var body: some View {
        TickingView(interval: BuildRing.shortestRedraw) { now in
            let model = RunningBlockModel(ids: ids, more: more, snapshot: snapshot, now: now)
            if !model.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    DayHeader(title: model.items.count == 1 ? String(localized: "Running") : model.spokenCount())
                        .padding(.leading, Self.headingInset)
                    card(model)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(model.spokenCount()))
                .accessibilitySortPriority(1)
            }
        }
    }

    // MARK: The card

    private func card(_ model: RunningBlockModel) -> some View {
        let single = model.items.count == 1 ? model.items.first : nil
        let selected = single.map { $0.id == selectedID } ?? false
        let tint = Self.tint(of: model, palette: palette)
        let fillOpacity = (tint == nil ? 0.05 : colorScheme == .dark ? 0.11 : 0.1) + (single != nil && isHovering && !selected ? 0.04 : 0)
        return Group {
            if let single {
                self.single(single, selected: selected)
            } else {
                nested(model)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? Color.primary).opacity(fillOpacity), in: .rect(cornerRadius: CumulusStyle.groupRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CumulusStyle.groupRadius)
                .strokeBorder(selected ? AnyShapeStyle(accent) : tint.map { AnyShapeStyle($0.opacity(0.3)) } ?? AnyShapeStyle(.quaternary), lineWidth: selected ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
    }

    /// The colour of the card: the app's when all the builds are of one app, none when they mix.
    static func tint(of model: RunningBlockModel, palette: AppPalette) -> Color? {
        guard !model.mixesApps, let key = model.items.first?.paletteKey else { return nil }
        return Color(nsColor: palette.swatch(for: key).nsColor)
    }

    // MARK: One build

    private func single(_ item: RunningBlockModel.Item, selected: Bool) -> some View {
        Button {
            select(item.id)
        } label: {
            HStack(spacing: 14) {
                BuildRingView(ring: item.ring, size: Self.singleSize, center: .text(item.centerText))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if let facts = item.facts {
                        Text(facts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Two or three builds

    private func nested(_ model: RunningBlockModel) -> some View {
        let stacked = width < Self.sideBySideWidth
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            ConcentricBuildRingsView(
                items: model.items.map { item in
                    ConcentricBuildRingsView.Item(ring: item.ring, paleTint: Color(nsColor: palette.swatch(for: item.paletteKey).nsColor))
                },
                size: Self.nestedSize, lineWidth: Self.nestedLineWidth, center: .text(model.centerCount().text)
            )
            .contentShape(.circle)
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    let index = RunningBlockHit.ringIndex(at: tap.location, size: Self.nestedSize, lineWidth: Self.nestedLineWidth, count: model.items.count)
                    select(model.items[index].id)
                }
            )
            .accessibilityHidden(true)
            .frame(maxWidth: stacked ? .infinity : nil)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.items) { item in legendRow(item, showsApp: model.mixesApps) }
                if model.more > 0, let showMore {
                    Button(action: showMore) {
                        Text(model.moreText())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Show the builds that are running"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendRow(_ item: RunningBlockModel.Item, showsApp: Bool) -> some View {
        let selected = item.id == selectedID
        let swatch = palette.swatch(for: item.paletteKey)
        return Button {
            select(item.id)
        } label: {
            HStack(spacing: 9) {
                if showsApp {
                    AppRoundIcon(name: item.appName, swatch: swatch, artwork: artwork[item.productID], diameter: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    ForEach(item.legendLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(LegendRowStyle(isSelected: selected, accent: accent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A legend line takes a light system fill under the pointer; the chosen build's line keeps a light fill of the accent
/// under its accent title, flat.
private struct LegendRowStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: .rect(cornerRadius: 8))
            .onHover { isHovering = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        if isSelected { return accent.opacity(pressed ? 0.2 : 0.12) }
        return Color.primary.opacity(pressed ? 0.12 : isHovering ? 0.06 : 0)
    }
}

#Preview("Running block") {
    let now = Date()
    let runs = (0..<3).map { index in
        CIBuildRun(
            id: "r\(index)", productID: "p\(index)", number: 40 + index, createdDate: now.addingTimeInterval(-300), startedDate: now.addingTimeInterval(-240),
            finishedDate: nil, executionProgress: .running, completionStatus: nil, startReason: nil, workflowID: "w\(index)", workflowName: "Release",
            sourceBranchOrTag: "main"
        )
    }
    return RunningBlockView(
        ids: runs.map(\.id), more: 0, snapshot: BuildSnapshot(runs: runs), selectedID: nil, select: { _ in }
    )
    .frame(width: 340)
}
