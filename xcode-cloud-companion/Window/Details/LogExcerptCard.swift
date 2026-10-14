import SwiftUI

/// What stands where the “Log Excerpt” card would be: the card with Cumulus Pro, the lock card without it, and nothing for
/// an action known to have left no log.
struct LogExcerptSection: View {
    let run: CIBuildRun
    let action: CIBuildAction
    let actionName: String
    let title: String
    let store: LogExcerptStore
    let logOpener: LogOpener
    let extras: BuildExtras?
    @Environment(ProAccess.self) private var access: ProAccess?

    var body: some View {
        if logOpener.offersLogs(for: action, knownArtifacts: extras?.artifactsByAction[action.id]) {
            if access.allows(.logExcerpt) {
                LogExcerptCard(run: run, action: action, actionName: actionName, title: title, store: store, logOpener: logOpener, extras: extras)
            } else {
                ProLockedCard(feature: .logExcerpt)
            }
        }
    }
}

/// The lines of the log around the error of the first action that failed. Opening the build reads the log only if it is
/// already unpacked on this Mac; the button downloads it. Until a download or a reading ends, the card is its own skeleton.
struct LogExcerptCard: View {
    let run: CIBuildRun
    let action: CIBuildAction
    let actionName: String
    let title: String
    let store: LogExcerptStore
    let logOpener: LogOpener
    let extras: BuildExtras?
    @State private var hasAttempted = false
    @State private var selected = 0
    @State private var isCopied = false

    var body: some View {
        let outcome = store.outcome(for: action.id)
        let isSkeleton = SkeletonRules.logExcerpt(hasOutcome: outcome != nil, isWorking: store.isWorking(action.id), hasAttempted: hasAttempted)
        content(outcome: outcome, isSkeleton: isSkeleton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cumulusGroup()
            .accessibilityElement(children: .contain)
            .skeleton(isSkeleton, label: "Log Excerpt, loading")
            .task(id: run.id) {
                await store.load(action, hints: hints)
                hasAttempted = true
            }
            .onChange(of: logOpener.state(of: action.id)) { _, state in
                if state == .idle { Task { await store.load(action, hints: hints) } }
            }
    }

    private var hints: [LogLocationHint] {
        LogLocationHint.hints(issues: extras?.issuesByAction[action.id] ?? [], tests: extras?.testsByAction[action.id] ?? [])
    }

    private var knownArtifacts: [CIArtifact]? {
        extras?.artifactsByAction[action.id]
    }

    @ViewBuilder
    private func content(outcome: LogExcerptStore.Outcome?, isSkeleton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isSkeleton {
                excerptContent(.placeholder)
            } else {
                switch outcome {
                case .found(let excerpt)?: excerptContent(excerpt)
                case .nothing?: nothingContent
                case .noLog?:
                    header(subtitle: actionName)
                    Text("This action left no log to read.").font(.callout).foregroundStyle(.secondary)
                case .failed(let message)?: promptContent(failure: message)
                case .notOnThisMac?, nil: promptContent(failure: nil)
                }
            }
        }
    }

    private func header(subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Log Excerpt", comment: "Heading of the card that shows the lines of a log around the error of a failed build")
                .fontWeight(.semibold)
                .unredacted()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - States

    @ViewBuilder
    private func excerptContent(_ excerpt: LogExcerpt) -> some View {
        let finding = excerpt.findings[min(selected, excerpt.findings.count - 1)]
        header(subtitle: UsageFormat.dotted([actionName, excerpt.fileName, LogExcerptFormat.position(finding, of: excerpt.totalLines)]))
        LogCodeBlock(finding: finding, totalLines: excerpt.totalLines)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { copyButton(finding); nextButton(excerpt); openButton }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { copyButton(finding); nextButton(excerpt) }
                openButton
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Attached to the “For AI” text", comment: "Chip on the log excerpt: the text for an AI assistant carries it")
            } icon: {
                Image(systemName: "paperclip")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: .capsule)
            Text("Read on this Mac, in the log of this build. Nothing is sent.", comment: "Under the log excerpt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nothingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(subtitle: actionName)
            Text("No line of this log reads as an error. Some failures leave none in the log.", comment: "In the log excerpt card, when the log holds no error line")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            openButton
        }
    }

    private func promptContent(failure: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(subtitle: actionName)
            Text("The log of this action is not on this Mac yet. Cumulus can download it and look for the line that says the error.", comment: "In the log excerpt card, before the log is downloaded")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(BuildStatus.errored.textTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Search in the Log") {
                Task {
                    selected = 0
                    await store.fetchAndLoad(
                        action, run: run, title: title, knownArtifacts: knownArtifacts,
                        signals: LogArchiveChoice.Signals(action: action, tests: extras?.testsByAction[action.id]), hints: hints
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Downloads this action’s log, reads it on this Mac and looks for the error")
        }
    }

    // MARK: - Buttons

    private func copyButton(_ finding: LogFinding) -> some View {
        Button {
            BuildFailureCopier.paste(LogExcerptFormat.text(of: finding))
            isCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                isCopied = false
            }
        } label: {
            if isCopied {
                Label("Copied", systemImage: "checkmark")
            } else {
                Label("Copy Excerpt", systemImage: "doc.on.doc")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("Copies the lines shown")
    }

    @ViewBuilder
    private func nextButton(_ excerpt: LogExcerpt) -> some View {
        if excerpt.findings.count > 1 {
            let index = min(selected, excerpt.findings.count - 1)
            Button("Next Error (\(index + 1) of \(excerpt.findings.count))") {
                selected = (index + 1) % excerpt.findings.count
            }
            .controlSize(.small)
            .help("Shows the next line of the log that says an error")
        }
    }

    private var openButton: some View {
        Button("Open Full Log") {
            Task { await logOpener.open(action, run: run, knownArtifacts: knownArtifacts, title: title) }
        }
        .controlSize(.small)
        .help("Opens the unpacked log in the Finder")
    }
}

/// The lines of one finding, in a fixed-width face with their numbers; the line of the error is marked with a word, not
/// with its colour alone.
struct LogCodeBlock: View {
    let finding: LogFinding
    let totalLines: Int

    var body: some View {
        let digits = String(max(totalLines, finding.lineNumber)).count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(finding.lines) { line in
                LogRow(line: line, isError: line.number == finding.lineNumber, digits: digits)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Excerpt of the log"))
        .accessibilityValue(Text(verbatim: finding.lines.map { row in
            (row.number == finding.lineNumber ? String(localized: "Error: ") : "") + LogExcerptFormat.line(row.text)
        }.joined(separator: "\n")))
    }
}

private struct LogRow: View {
    let line: LogLine
    let isError: Bool
    let digits: Int
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(line.number))
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(digits) * 6.8, alignment: .trailing)
            Text(verbatim: line.text.isEmpty ? " " : LogExcerptFormat.line(line.text))
                .fontWeight(isError ? .semibold : .regular)
                .lineLimit(isError ? 3 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isError {
                Text("error", comment: "Marks the line of the log that says an error")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(redaction.isSkeleton ? AnyShapeStyle(Color.skeleton) : AnyShapeStyle(.foreground), lineWidth: 1))
                    .fixedSize()
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .foregroundStyle(isError && !redaction.isSkeleton ? BuildStatus.failed.textTint : Color.primary)
        .background(isError ? (redaction.isSkeleton ? Color.skeleton : BuildStatus.failed.tint.opacity(0.14)) : Color.clear)
    }
}
