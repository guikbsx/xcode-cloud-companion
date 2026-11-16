import AppKit
import SwiftUI

/// Brings a failed build's text together for an AI assistant. Showing the text asks Apple for nothing; making it loads
/// the issues and the test results the way the build's tabs do, once, and not while the hour's requests are nearly spent.
/// Artifacts are told only if already loaded, and logs only if already unpacked.
struct BuildFailureCopier {
    let buildStore: BuildStore
    let extrasStore: BuildExtrasStore
    var logOpener: LogOpener?
    /// The log excerpt: added to the text only when the log is already unpacked.
    var excerpts: LogExcerptStore?

    /// What is known now, with no request.
    func knownPrompt(for run: CIBuildRun) -> BuildFailurePrompt {
        BuildFailurePrompt(run: run, snapshot: buildStore.snapshot, extras: extrasStore.extras(for: run.id))
    }

    /// The text with what the tabs would load. A part that fails to load is said so in the text.
    func loadedPrompt(for run: CIBuildRun) async -> BuildFailurePrompt {
        let actions = buildStore.snapshot.actionsByRunID[run.id] ?? []
        await extrasStore.loadCached(run)
        if !actions.isEmpty, !isComplete(run) {
            await buildStore.updateRateLimit()
            let isShort = buildStore.rateLimit.map { $0.remaining <= SyncSchedule.criticalRemaining } ?? false
            if !isShort {
                await extrasStore.loadIssues(for: run, actions: actions)
                await extrasStore.loadTests(for: run, actions: actions)
                await settle(.issues, runID: run.id)
                await settle(.tests, runID: run.id)
            }
        }
        var folders: [String: String] = [:]
        for action in actions where action.executionProgress == .complete {
            if let folder = await logOpener?.unpackedFolder(of: action.id) { folders[action.id] = folder.path(percentEncoded: false) }
        }
        let extras = extrasStore.extras(for: run.id)
        let excerpt = await excerpts?.excerptForPrompt(actions: actions, extras: extras)
        return BuildFailurePrompt(
            run: run, snapshot: buildStore.snapshot, extras: extras, logFolders: folders,
            logExcerpt: excerpt.map { BuildFailurePrompt.LogSection(actionName: $0.actionName, excerpt: $0.excerpt) }
        )
    }

    func copy(_ run: CIBuildRun) async {
        Self.paste(await loadedPrompt(for: run).text)
    }

    static func paste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func isComplete(_ run: CIBuildRun) -> Bool {
        let extras = extrasStore.extras(for: run.id)
        return extras?.issuesComplete == true && extras?.testsComplete == true
    }

    /// A tab may already be loading the same part: wait for it instead of reading nothing.
    private func settle(_ part: BuildExtrasStore.Part, runID: String) async {
        for _ in 0..<80 {
            guard case .loading = extrasStore.state(part, runID: runID) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

enum BuildFailureCopyPhase {
    case idle, loading, copied
}

/// The “For AI” card of a failed build's sheet: the start of the text, what it holds, and the ways to take it.
struct BuildFailureCard: View {
    let run: CIBuildRun
    let copier: BuildFailureCopier
    @State private var phase = BuildFailureCopyPhase.idle
    @State private var isShowingText = false
    @State private var fullText = ""

    var body: some View {
        let prompt = copier.knownPrompt(for: run)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(CumulusStyle.accent)
                    .accessibilityHidden(true)
                Text("For AI", comment: "Heading of the card that offers a failed build as text for an AI assistant")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)

            Text(prompt.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Start of the text for an AI assistant"))
                .accessibilityValue(Text(prompt.preview))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    summary(prompt.facts)
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 8) {
                    summary(prompt.facts)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        buttons
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
        .popover(isPresented: $isShowingText, arrowEdge: .bottom) {
            BuildFailureTextView(text: fullText, phase: phase, copy: { Task { await copy() } })
        }
    }

    @ViewBuilder
    private func summary(_ facts: BuildFailurePrompt.Facts) -> some View {
        let parts: [String?] = [
            facts.errorCount.flatMap { $0 > 0 ? String(localized: "\($0) errors") : nil },
            facts.failedTestCount.flatMap { $0 > 0 ? String(localized: "\($0) failed tests", comment: "Count of failed tests in the summary of the “For AI” card") : nil },
            facts.hasCommit ? String(localized: "the commit", comment: "Part of the summary of the “For AI” card: the text includes the build's commit") : nil,
            facts.referenceNumber.map { String(localized: "last success #\($0)", comment: "Part of the summary of the “For AI” card: the number of the last build that succeeded") },
        ]
        let line = UsageFormat.dotted(parts.compactMap(\.self))
        if !line.isEmpty {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Show Full Text") { Task { await showFullText() } }
                .buttonStyle(.link)
                .font(.callout)
                .help("Shows the whole text, loading the issues and test results first")
            Button {
                Task { await copy() }
            } label: {
                switch phase {
                case .idle:
                    Label("Copy", systemImage: "doc.on.doc")
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Copy")
                    }
                case .copied:
                    Label("Copied", systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel(Text(phase == .copied ? "Copied" : "Copy the text for an AI assistant"))
            .help("Copies the text for an AI assistant, loading the issues and test results first")
        }
    }

    private func prepare() async -> String? {
        guard phase != .loading else { return nil }
        phase = .loading
        let text = await copier.loadedPrompt(for: run).text
        fullText = text
        phase = .idle
        return text
    }

    private func copy() async {
        guard let text = await prepare() else { return }
        BuildFailureCopier.paste(text)
        phase = .copied
        try? await Task.sleep(for: .seconds(2))
        if phase == .copied { phase = .idle }
    }

    private func showFullText() async {
        guard phase != .loading else { return }
        isShowingText = true
        _ = await prepare()
    }
}

/// The whole text, to read and select, with its own Copy.
struct BuildFailureTextView: View {
    let text: String
    let phase: BuildFailureCopyPhase
    let copy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if text.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            Divider()
            HStack {
                Text("Data from Xcode Cloud, for an AI assistant", comment: "Caption under the full text of the “For AI” card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    switch phase {
                    case .idle: Label("Copy", systemImage: "doc.on.doc")
                    case .loading:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Copy")
                        }
                    case .copied: Label("Copied", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(Text(phase == .copied ? "Copied" : "Copy the text for an AI assistant"))
            }
            .padding(10)
        }
        .frame(width: 560, height: 420)
    }
}
