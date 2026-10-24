import Observation
import SwiftUI

/// What the user did with the parts of the build sheets in this window, build by build, and the parts other screens ask
/// to see. It lives with the window: closing a sheet and opening it again finds the parts as they were left.
@Observable
final class BuildPartsState {
    /// A part another screen wants on show: opened, then scrolled to.
    struct Request: Equatable {
        let runID: String
        let part: BuildPart
        let serial: Int
    }

    private var choices: [String: [BuildPart: Bool]] = [:]
    private(set) var request: Request?
    private var serial = 0

    /// The user's choice for this part of this build, else the card's own default.
    func isExpanded(_ part: BuildPart, runID: String, byDefault: Bool) -> Bool {
        choices[runID]?[part] ?? byDefault
    }

    func setExpanded(_ isExpanded: Bool, part: BuildPart, runID: String) {
        choices[runID, default: [:]][part] = isExpanded
    }

    /// Opens a part of a build's sheet and brings it into view, whichever build is on screen now.
    func show(_ part: BuildPart, ofRun runID: String) {
        setExpanded(true, part: part, runID: runID)
        serial += 1
        request = Request(runID: runID, part: part, serial: serial)
    }

    /// The sheet has scrolled to the request: it is not asked again.
    func finish(_ finished: DetailScrollTarget) {
        if let request, request.serial == finished.serial { self.request = nil }
    }
}

/// The detail of a build in one card: its parts one under another, the one that holds the cause first, each with a line
/// that opens and closes it. A closed part asks Apple for nothing; its line says what the app already knows.
struct BuildPartsCard<Content: View>: View {
    let run: CIBuildRun
    let state: BuildPartsState
    let counter: (BuildPart) -> BuildPartCounter
    /// Reads a part's data; called while the part is open, when it opens and when the build changes.
    let load: (BuildPart) async -> Void
    @ViewBuilder let content: (BuildPart) -> Content
    /// Worked out when the sheet opens, and kept: nothing changes place while the sheet is read.
    @State private var order: BuildSheetOrder

    init(
        run: CIBuildRun, facts: BuildSheetOrder.Facts, state: BuildPartsState, counter: @escaping (BuildPart) -> BuildPartCounter,
        load: @escaping (BuildPart) async -> Void, @ViewBuilder content: @escaping (BuildPart) -> Content
    ) {
        self.run = run
        self.state = state
        self.counter = counter
        self.load = load
        self.content = content
        _order = State(initialValue: BuildSheetOrder(facts))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(order.parts, id: \.self) { part in
                if part != order.parts.first { Divider() }
                section(part)
                    .id(part)
            }
            if let footnote = order.footnote {
                Divider()
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusFlatGroup()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Build Details"))
    }

    private func isOpen(_ part: BuildPart) -> Bool {
        state.isExpanded(part, runID: run.id, byDefault: order.expanded.contains(part))
    }

    @ViewBuilder
    private func section(_ part: BuildPart) -> some View {
        let open = isOpen(part)
        VStack(spacing: 0) {
            header(part, isOpen: open)
            if open {
                Divider()
                content(part)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: run) { await load(part) }
            }
        }
    }

    private func header(_ part: BuildPart, isOpen: Bool) -> some View {
        let counter = counter(part)
        return Button {
            state.setExpanded(!isOpen, part: part, runID: run.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: part.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(part.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                counterView(counter)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(part.title))
        .accessibilityValue(Text(UsageFormat.dotted([isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"), counter.isEmpty ? nil : counter.text].compactMap(\.self))))
        .accessibilityHint(Text(isOpen ? "Hides this part" : "Shows this part"))
    }

    private func counterView(_ counter: BuildPartCounter) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(counter.pieces.enumerated()), id: \.offset) { index, piece in
                if index > 0 { Text(verbatim: " · ").foregroundStyle(.secondary) }
                Text(piece.text)
                    .fontWeight(piece.isAlert ? .semibold : .regular)
                    .foregroundStyle(piece.isAlert ? AnyShapeStyle(BuildStatus.failed.textTint) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .accessibilityHidden(true)
    }
}
