import SwiftUI

/// What the sheet is about to do: start a workflow on a branch, a tag or a pull request, or rebuild a run.
struct LaunchTarget: Identifiable {
    enum Mode {
        case launch(CIWorkflow, preferredReference: String?)
        case rebuild(CIBuildRun, CIWorkflow)
    }

    let mode: Mode
    let productID: String
    /// The workflow's runs the cache holds: they say what the last build on a source did.
    var recentRuns: [CIBuildRun] = []

    var id: String {
        switch mode {
        case .launch(let workflow, _): "launch-\(workflow.id)"
        case .rebuild(let run, _): "rebuild-\(run.id)"
        }
    }

    var workflow: CIWorkflow {
        switch mode {
        case .launch(let workflow, _), .rebuild(_, let workflow): workflow
        }
    }
}

/// The confirmation before anything is sent: it names the workflow and the source, and says what cannot be undone.
struct LaunchSheet: View {
    let target: LaunchTarget
    let launcher: BuildLauncher
    let onStarted: (CIBuildRun) -> Void
    let onNotAllowed: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var choices: LaunchChoices?
    @State private var kind = LaunchSourceKind.branch
    @State private var branchID: String?
    @State private var tagID: String?
    @State private var pullRequestID: String?
    @State private var query = ""
    @State private var clean = false
    @State private var result: LaunchOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            if case .launch = target.mode {
                sourceSection
            }
            Toggle("Clean build", isOn: $clean)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let result, let message = Self.message(for: result) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSend)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { await loadChoices() }
    }

    private var title: String {
        switch target.mode {
        case .launch(let workflow, _): String(localized: "Launch “\(workflow.name)”?")
        case .rebuild(let run, let workflow): String(localized: "Rebuild \(run.number.map { "#\($0)" } ?? "this build") of “\(workflow.name)”?")
        }
    }

    private var confirmTitle: String {
        if case .rebuild = target.mode { String(localized: "Rebuild") } else { String(localized: "Launch") }
    }

    private var explanation: String {
        switch target.mode {
        case .launch:
            switch kind {
            case .branch:
                String(localized: "Xcode Cloud starts a manual build and uses compute hours. The workflow needs a manual start condition that matches this branch. Cumulus cannot cancel it.")
            case .tag:
                String(localized: "Xcode Cloud starts a manual build and uses compute hours. The workflow needs a manual start condition that matches this tag. Cumulus cannot cancel it.")
            case .pullRequest:
                String(localized: "Xcode Cloud starts a manual build and uses compute hours. The workflow needs a manual start condition that matches this pull request. Cumulus cannot cancel it.")
            }
        case .rebuild:
            String(localized: "Xcode Cloud repeats this build and uses compute hours. Cumulus cannot cancel it.")
        }
    }

    private var canSend: Bool {
        if launcher.isLaunching { return false }
        if case .launch = target.mode { return selectedSource != nil }
        return true
    }

    /// The one source the request will name, for the kind on screen.
    private var selectedSource: LaunchSource? {
        switch kind {
        case .branch: branchID.map { .gitReference(id: $0) }
        case .tag: tagID.map { .gitReference(id: $0) }
        case .pullRequest: pullRequestID.map { .pullRequest(id: $0) }
        }
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceSection: some View {
        if let choices {
            Picker("Source", selection: $kind) {
                Text("Branch").tag(LaunchSourceKind.branch)
                Text("Tag").tag(LaunchSourceKind.tag)
                Text("Pull request").tag(LaunchSourceKind.pullRequest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { query = "" }
            switch kind {
            case .branch:
                referenceMenu(choices.branches, label: String(localized: "Branch"), selection: $branchID, empty: String(localized: "No branch was found for this workflow."))
            case .tag:
                referenceMenu(choices.tags, label: String(localized: "Tag"), selection: $tagID, empty: String(localized: "No tag was found for this workflow."))
            case .pullRequest:
                pullRequestMenu(choices)
            }
            if let detail = sourceDetail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading branches, tags and pull requests…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func referenceMenu(_ references: [GitReference], label: String, selection: Binding<String?>, empty: String) -> some View {
        if references.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            let matched = LaunchChoices.matching(references, query: query, name: \.name)
            filterField(count: references.count)
            Picker(label, selection: selection) {
                ForEach(matched.shown) { reference in
                    Text(reference.name).tag(Optional(reference.id))
                }
            }
            .onChange(of: query) { keepSelection(selection, among: matched.shown.map(\.id)) }
            truncationNote(shown: matched.shown.count, total: matched.total)
        }
    }

    @ViewBuilder
    private func pullRequestMenu(_ choices: LaunchChoices) -> some View {
        if let pullRequests = choices.pullRequests {
            if pullRequests.isEmpty {
                Text("No open pull request was found for this workflow.").foregroundStyle(.secondary)
            } else {
                let matched = LaunchChoices.matching(pullRequests, query: query, name: \.label)
                filterField(count: pullRequests.count)
                Picker("Pull request", selection: $pullRequestID) {
                    ForEach(matched.shown) { pullRequest in
                        Text(pullRequest.label).tag(Optional(pullRequest.id))
                    }
                }
                .onChange(of: query) { keepSelection($pullRequestID, among: matched.shown.map(\.id)) }
                truncationNote(shown: matched.shown.count, total: matched.total)
            }
        } else {
            Text("The pull requests couldn’t be read. Branches and tags are still available.").foregroundStyle(.secondary)
        }
    }

    /// Past a dozen names a menu is slow to read: typing narrows it.
    @ViewBuilder
    private func filterField(count: Int) -> some View {
        if count > LaunchChoices.filterThreshold {
            TextField("Filter", text: $query, prompt: Text("Type to narrow the list"))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func truncationNote(shown: Int, total: Int) -> some View {
        if total > shown {
            Text("Showing \(shown) of \(total). Type to narrow the list.").font(.caption).foregroundStyle(.secondary)
        } else if total == 0 {
            Text("Nothing matches.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A selection that the filter hid would be sent unseen: the first name shown takes its place.
    private func keepSelection(_ selection: Binding<String?>, among shown: [String]) {
        guard let current = selection.wrappedValue, !shown.contains(current) else { return }
        selection.wrappedValue = shown.first
    }

    /// What the cache knows about the source on screen: for a pull request its branches too.
    private var sourceDetail: String? {
        guard let choices else { return nil }
        let now = Date()
        switch kind {
        case .branch, .tag:
            let references = kind == .branch ? choices.branches : choices.tags
            let selected = kind == .branch ? branchID : tagID
            guard let name = references.first(where: { $0.id == selected })?.name,
                  let run = LaunchSourceHistory.lastRun(onBranchOrTag: name, in: target.recentRuns)
            else { return nil }
            return Self.lastBuildLine(run, now: now)
        case .pullRequest:
            guard let pullRequest = choices.pullRequests?.first(where: { $0.id == pullRequestID }) else { return nil }
            var parts: [String] = []
            if let source = pullRequest.sourceBranch, let destination = pullRequest.destinationBranch {
                parts.append(String(localized: "\(source) into \(destination)", comment: "The two branches of a pull request: the source branch, then the one it goes into."))
            }
            if pullRequest.isCrossRepository {
                parts.append(String(localized: "from another repository"))
            }
            if let run = LaunchSourceHistory.lastRun(onPullRequest: pullRequest.number, in: target.recentRuns) {
                parts.append(Self.lastBuildLine(run, now: now))
            }
            return parts.isEmpty ? nil : UsageFormat.dotted(parts)
        }
    }

    static func lastBuildLine(_ run: CIBuildRun, now: Date) -> String {
        let status = BuildStatus(run: run)
        guard let date = run.createdDate else { return String(localized: "Last build: \(status.label)") }
        return String(localized: "Last build: \(status.label), \(UsageFormat.relative(date, now: now))", comment: "Under the launch menu: the state of the last build on this source and when it was, e.g. “Last build: Succeeded, 12 minutes ago”.")
    }

    // MARK: - Loading and sending

    private func loadChoices() async {
        guard case .launch(let workflow, let preferred) = target.mode else { return }
        let loaded = await launcher.choices(for: workflow.id) ?? LaunchChoices(references: [], pullRequests: [])
        choices = loaded
        kind = loaded.kind(of: preferred)
        branchID = loaded.branches.first { $0.name == preferred }?.id
            ?? loaded.branches.first { ["main", "master", "develop"].contains($0.name) }?.id
            ?? loaded.branches.first?.id
        tagID = loaded.tags.first { $0.name == preferred }?.id ?? loaded.tags.first?.id
        pullRequestID = loaded.pullRequests?.first?.id
    }

    private func send() async {
        let request: BuildRunRequest
        switch target.mode {
        case .launch(let workflow, _):
            guard let source = selectedSource else { return }
            request = .launch(workflowID: workflow.id, source: source, clean: clean)
        case .rebuild(let run, let workflow):
            request = .rebuild(buildRunID: run.id, workflowID: workflow.id, clean: clean)
        }
        let outcome = await launcher.launch(request, productID: target.productID, workflowName: target.workflow.name)
        switch outcome {
        case .started(let run):
            onStarted(run)
            dismiss()
        case .uncertain(let found?):
            onStarted(found)
            dismiss()
        case .notAllowed:
            result = outcome
            onNotAllowed()
        default:
            result = outcome
        }
    }

    static func message(for outcome: LaunchOutcome) -> String? {
        switch outcome {
        case .started: nil
        case .notAllowed(let message): message
        case .refused(let message, let pointsAtSource):
            pointsAtSource ? UsageFormat.dotted([message, String(localized: "Pick another branch, tag or pull request.")]) : message
        case .rateLimited: String(localized: "Apple’s hourly request limit is reached. Nothing was started; try again later.")
        case .failed(let message): message
        case .accepted: String(localized: "Apple accepted the launch. The build is not in the list yet: it will show at the next sync. Do not launch it again.")
        case .uncertain(let found):
            found == nil ? String(localized: "Apple did not confirm the launch, and the build list shows no new build. Nothing seems to have started; you can try again.") : nil
        case .unknown: String(localized: "Apple did not confirm the launch, and the build list could not be read: a build may have started. Check the list of builds before trying again.")
        }
    }
}
