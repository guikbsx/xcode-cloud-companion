import SwiftUI

/// What runs, large, at the head of the build list: one ring for a single build, nested rings with a legend for two or three
/// (the ones that end first), laid flat as the first row of the list: no surface, no border. Redrawn every ten seconds and at every sync, never per frame.
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

    static let singleSize: CGFloat = 96
    static let nestedSize: CGFloat = 120
    static let nestedLineWidth: CGFloat = 10
    /// Below this width the legend goes under the rings.
    static let sideBySideWidth: CGFloat = 310

    @State private var width: CGFloat = 340
    @Environment(\.colorScheme) private var colorScheme

    private var selectedInk: Color {
        colorScheme == .dark ? CumulusStyle.accent.mix(with: .white, by: 0.2) : CumulusStyle.accent
    }

    var body: some View {
        TickingView(interval: BuildRing.shortestRedraw) { now in
            let model = RunningBlockModel(ids: ids, more: more, snapshot: snapshot, now: now)
            if !model.items.isEmpty {
                surface(model)
            }
        }
    }

    private func surface(_ model: RunningBlockModel) -> some View {
        Group {
            if model.items.count == 1, let item = model.items.first {
                single(item)
            } else {
                nested(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(model.spokenCount()))
        .accessibilitySortPriority(1)
    }

    // MARK: One build

    private func single(_ item: RunningBlockModel.Item) -> some View {
        let selected = item.id == selectedID
        return Button {
            select(item.id)
        } label: {
            HStack(spacing: 16) {
                BuildRingView(
                    ring: item.ring, size: Self.singleSize, center: .text(item.centerText, detail: item.centerDetail), isSelected: selected
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UsageFormat.dotted([item.title, item.workflow].compactMap(\.self)))
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)
                    Text(item.action)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let reference = item.reference {
                        Text(reference)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        let count = model.centerCount()
        return layout {
            ConcentricBuildRingsView(
                items: model.items.map { item in
                    ConcentricBuildRingsView.Item(ring: item.ring, paleTint: Color(nsColor: palette.swatch(for: item.paletteKey).nsColor))
                },
                size: Self.nestedSize, lineWidth: Self.nestedLineWidth, center: .text(count.text, detail: count.detail)
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
                        .foregroundStyle(selected ? AnyShapeStyle(selectedInk) : AnyShapeStyle(.primary))
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
        .buttonStyle(LegendRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A legend line takes a light system fill under the pointer; the chosen build's line is told by its accent title, with
/// nothing drawn around it (see `legendRow`).
private struct LegendRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.06 : 0), in: .rect(cornerRadius: 8)
            )
            .onHover { isHovering = $0 }
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
