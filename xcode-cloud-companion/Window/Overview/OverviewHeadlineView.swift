import SwiftUI

/// The line at the top of the Overview: the day and the account on the left; what runs and the plan on the right.
struct OverviewAccountLineView: View {
    let line: OverviewAccountLine
    let openBuild: (String) -> Void
    let openSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                identity
                Spacer(minLength: 0)
                status(wraps: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                identity
                status(wraps: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                identity
                status(wraps: true)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(OverviewColors.rule).frame(height: 1) }
    }

    private var identity: some View {
        Text(UsageFormat.dotted([line.day, line.time, line.account]))
            .fontWeight(.medium)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// On one line, or, when the column is too narrow for that, each part under the other and free to wrap.
    @ViewBuilder
    private func status(wraps: Bool) -> some View {
        if wraps {
            VStack(alignment: .leading, spacing: 4) {
                if let running = line.running { runningButton(running, wraps: true) }
                plan
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 7) {
                if let running = line.running {
                    runningButton(running, wraps: false)
                    Text(verbatim: "·").opacity(0.5).padding(.horizontal, 2).accessibilityHidden(true)
                }
                plan
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func runningButton(_ running: OverviewAccountLine.Running, wraps: Bool) -> some View {
        Button {
            openBuild(running.runID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().strokeBorder(OverviewColors.running, lineWidth: 1.6).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(running.text).lineLimit(wraps ? 3 : 1).multilineTextAlignment(.leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open the build")
    }

    @ViewBuilder
    private var plan: some View {
        switch line.plan {
        case .set(let used, let quota, let isEstimate):
            let value = Text((isEstimate ? "~" : "") + used).fontWeight(.semibold).foregroundStyle(.primary).monospacedDigit()
            Group {
                if isEstimate {
                    Text("Plan \(value) of \(quota), estimated")
                } else {
                    Text("Plan \(value) of \(quota)")
                }
            }
            .accessibilityLabel(OverviewScreenWords().planAccessibility(used: used, quota: quota, isEstimate: isEstimate))
        case .missing:
            Button("Enter your plan", action: openSettings)
                .buttonStyle(.link)
                .foregroundStyle(Color.accentColor)
        case .measuring:
            Text("Measuring usage…")
        }
    }
}

/// The headline: one sentence in 64 points with its emphasized words in the colour of the state, a lead, and the buttons.
struct OverviewTitleView: View {
    let title: OverviewHeadline.Title
    /// The width of the column, which sets the size of the type.
    let width: CGFloat
    /// Copies the failed build as text for an AI assistant; it is done when it returns.
    let copyForAI: (String) async -> Void
    let perform: (OverviewHeadline.Action) -> Void
    @State private var copyPhase: CopyPhase = .idle

    private enum CopyPhase: Equatable {
        case idle, copying(String), copied(String)
    }

    private var size: CGFloat { width >= 900 ? 64 : width >= 560 ? 48 : 36 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(attributedTitle)
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.034)
                .lineSpacing(-size * 0.14)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(10)
                .padding(.top, 6)
            if let lead = title.lead {
                Text(lead)
                    .font(.system(size: width >= 560 ? 17 : 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !title.actions.isEmpty {
                HStack(spacing: 18) {
                    ForEach(Array(title.actions.enumerated()), id: \.offset) { _, choice in
                        button(choice)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var attributedTitle: AttributedString {
        var text = AttributedString()
        for part in title.parts {
            var piece = AttributedString(part.text)
            if part.isEmphasized {
                piece.foregroundColor = OverviewColors.ink(title.tone)
            } else if title.tone == .good {
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }

    @ViewBuilder
    private func button(_ choice: OverviewHeadline.Choice) -> some View {
        if case .copyForAI(let runID) = choice.action {
            Button {
                Task {
                    copyPhase = .copying(runID)
                    await copyForAI(runID)
                    copyPhase = .copied(runID)
                    try? await Task.sleep(for: .seconds(2))
                    if copyPhase == .copied(runID) { copyPhase = .idle }
                }
            } label: {
                switch copyPhase {
                case .copying(runID): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(choice.title) }
                case .copied(runID): Label("Copied", systemImage: "checkmark")
                default: Text(choice.title)
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 13, weight: .semibold))
            .help("Copies the text for an AI assistant, loading the issues and test results first")
        } else {
            Button(choice.title) { perform(choice.action) }
                .buttonStyle(.link)
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

/// The small notes under or beside the figure: a label in small capitals, a sentence, a grey line, thin rules between.
struct OverviewNotesView: View {
    let notes: [OverviewHeadline.Note]
    let placement: OverviewFigureLayout.NotesPlacement
    let width: CGFloat
    let open: (OverviewHeadline.Target) -> Void

    var body: some View {
        if !notes.isEmpty {
            switch placement {
            case .beside:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Rectangle().fill(OverviewColors.rule).frame(height: 1).padding(.vertical, 14) }
                        view(of: note)
                    }
                }
            case .below:
                let columns = OverviewFigureLayout.noteColumns(count: notes.count, width: width)
                Group {
                    if columns > 1 {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                view(of: note)
                                    .padding(.leading, index == 0 ? 0 : 22)
                                    .padding(.trailing, index == notes.count - 1 ? 0 : 22)
                                    .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(OverviewColors.rule).frame(width: 1) } }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                if index > 0 { Rectangle().fill(OverviewColors.rule).frame(height: 1).padding(.vertical, 12) }
                                view(of: note)
                            }
                        }
                    }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(OverviewColors.rule).frame(height: 1) }
            }
        }
    }

    @ViewBuilder
    private func view(of note: OverviewHeadline.Note) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(note.label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Self.ink(of: note))
            Text(note.sentence)
                .font(.system(size: 15, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = note.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let target = note.target {
            Button { open(target) } label: { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    static func ink(of note: OverviewHeadline.Note) -> Color {
        switch note.kind {
        case .broken: BuildStatus.failed.textTint
        case .plan, .stuck, .slowdown, .apple: BuildStatus.errored.textTint
        case .testFlight: CumulusStyle.accent.mix(with: .primary, by: 0.15)
        case .flakyTests: Color.purple.mix(with: .primary, by: 0.2)
        case .xcode: .secondary
        }
    }
}
