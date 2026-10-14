import SwiftUI

/// What a row needs to show the history of its test: the workflow whose builds it reads, the model that reads them, and
/// the way to a build.
struct TestHistoryAccess {
    let workflowID: String
    let tests: WorkflowTestsModel
    /// Opens a build on its Tests tab.
    let openBuild: (String) -> Void
}

/// One build in the row of squares. The three states differ by their shape, not only by their colour: a plain square,
/// a taller one, an empty outline; a build where the test did not run is a dot.
struct TestOutcomeShape: View {
    let outcome: TestHistory.Outcome
    var width: CGFloat = 14
    var height: CGFloat = 14
    var tall: CGFloat = 18
    var cornerRadius: CGFloat = 3
    var outline: CGFloat = 2
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        switch outcome {
        case .passed:
            RoundedRectangle(cornerRadius: cornerRadius).fill(shown(BuildStatus.succeeded.tint).opacity(0.45)).frame(width: width, height: height)
        case .failed:
            RoundedRectangle(cornerRadius: cornerRadius).fill(shown(BuildStatus.failed.tint)).frame(width: width, height: tall)
        case .mixed:
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(shown(BuildStatus.errored.tint), lineWidth: outline).frame(width: width, height: height)
        case .absent:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3).frame(width: width, height: height)
        }
    }

    private func shown(_ color: Color) -> Color {
        redaction.isSkeleton ? Color.skeleton : color
    }
}

/// The miniature row of a flaky test in a workflow's Tests section.
struct TestHistoryMiniStrip: View {
    let outcomes: [TestHistory.Outcome]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                TestOutcomeShape(outcome: outcome, width: 3, height: 10, tall: 14, cornerRadius: 0, outline: 1)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The words for a history, in one place: the squares' labels, the summary VoiceOver reads and the miniature's caption.
nonisolated enum TestHistoryText {
    static func label(of outcome: TestHistory.Outcome) -> String {
        switch outcome {
        case .passed: String(localized: "Passed")
        case .failed: String(localized: "Failed")
        case .mixed: String(localized: "Flaky", comment: "A test that passed on some devices and failed on others in one build")
        case .absent: String(localized: "Not run", comment: "A build where the test did not run, or gave no verdict")
        }
    }

    static func label(of entry: TestHistory.Entry) -> String {
        let state = label(of: entry.outcome)
        guard let number = entry.number else { return state }
        return String(localized: "\(state), build \(number)", comment: "VoiceOver: one square of a test's history, its state then the build number")
    }

    static func failures(_ count: Int) -> String {
        String(localized: "\(count) failures", comment: "Number of builds where a test failed")
    }

    static func flakyPasses(_ count: Int) -> String {
        String(localized: "\(count) flaky passes", comment: "Number of builds where a test passed on some devices and failed on others")
    }

    static func builds(_ count: Int) -> String {
        String(localized: "\(count) builds")
    }

    /// “4 failures and 2 flaky passes”, or “No failure” when there is none.
    static func results(failed: Int, mixed: Int) -> String {
        if failed == 0, mixed == 0 { return String(localized: "No failure") }
        return [failed > 0 ? failures(failed) : nil, mixed > 0 ? flakyPasses(mixed) : nil].compactMap(\.self).formatted(.list(type: .and, width: .standard))
    }

    /// What VoiceOver reads for the row of squares: “4 failures and 2 flaky passes in 30 builds”.
    static func summary(of history: TestHistory) -> String {
        String(localized: "\(results(failed: history.failedCount, mixed: history.mixedCount)) in \(builds(history.analyzedBuilds))", comment: "VoiceOver: summary of a test's history, such as “4 failures and 2 flaky passes in 30 builds”")
    }
}

/// The history of one test as the popover shows it. It takes the history already read (nil while it is read) and draws
/// it; reading is the wrapper's work, so this can be hosted as it is.
struct TestHistoryContent: View {
    let identity: TestHistory.Identity
    /// Nil while the history is being read: the view then stands as its own skeleton.
    let history: TestHistory?
    var isReading: Bool
    /// Opens a build on its Tests tab.
    let openBuild: (String) -> Void
    /// Opens a file of the local clone in Xcode; nil when this window has none for the app.
    var opening: SourceOpening?
    /// Cumulus Pro opens a file of the local clone.
    var xcodeIsOpen = true
    var showPurchase: () -> Void = {}
    @State private var failure: String?

    static let width: CGFloat = 548

    var body: some View {
        let shown = history ?? .placeholder
        VStack(alignment: .leading, spacing: 12) {
            header(shown)
            if shown.entries.isEmpty {
                Text("None of the builds analyzed holds this test.")
                    .foregroundStyle(.secondary)
            } else {
                strip(shown)
                legend
                facts(shown)
                actions(shown)
            }
            Text("Based on \(shown.analyzedBuilds) builds analyzed of \(shown.eligibleBuilds).", comment: "Foot of a test's history: how many builds it read among the finished builds of the workflow")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .skeleton(isReading)
    }

    private func header(_ shown: TestHistory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(identity.title)
                .fontWeight(.semibold)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if shown.isFlaky {
                CapsuleTag(text: String(localized: "Flaky", comment: "A test that passed on some devices and failed on others in one build"), systemImage: "arrow.left.arrow.right", tint: BuildStatus.errored.textTint)
            }
        }
    }

    private func strip(_ shown: TestHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(shown.entries) { entry in
                    Button {
                        openBuild(entry.runID)
                    } label: {
                        TestOutcomeShape(outcome: entry.outcome)
                            .frame(width: 14, height: 18, alignment: .bottom)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(TestHistoryText.label(of: entry))
                    .accessibilityHint(Text("Opens the build on its Tests tab"))
                    .help(TestHistoryText.label(of: entry))
                }
            }
            HStack {
                Text("Oldest")
                Spacer()
                Text("Newest")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .unredacted()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TestHistoryText.summary(of: shown))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach([TestHistory.Outcome.passed, .failed, .mixed], id: \.self) { outcome in
                HStack(spacing: 6) {
                    TestOutcomeShape(outcome: outcome, width: 10, height: 10, tall: 13, cornerRadius: 2)
                    Text(TestHistoryText.label(of: outcome))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func facts(_ shown: TestHistory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                fact("Results") {
                    Text(TestHistoryText.results(failed: shown.failedCount, mixed: shown.mixedCount))
                }
                fact("Current streak") {
                    if let streak = shown.currentStreak {
                        Text("Began at \(Self.build(streak.first))", comment: "The first failure of the failing streak a test is in: its build, its day, its commit")
                    } else {
                        Text("None")
                    }
                }
            }
            fact("Average time") {
                let averages = shown.averageSecondsPerDevice
                if averages.isEmpty {
                    Text("None")
                } else {
                    Text(averages.map { String(localized: "\(Self.duration($0.seconds)) on \($0.name)", comment: "A test's mean time on one device, such as “1.8 s on iPhone 17”") }
                        .formatted(.list(type: .and, width: .narrow)))
                }
            }
            fact("Last failure message") {
                if let message = shown.lastFailureMessage {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                } else {
                    Text("None")
                }
            }
        }
    }

    private func fact(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ shown: TestHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let last = shown.lastFailure {
                    Button("Open Last Failure") { openBuild(last.runID) }
                        .buttonStyle(.borderedProminent)
                }
                xcodeButton(shown.lastFailure?.file)
            }
            .controlSize(.small)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(BuildStatus.errored.tint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func xcodeButton(_ file: CIFileLocation?) -> some View {
        if let path = file?.path {
            if SourceActions.existsLocally(path) {
                Button("Open in Xcode") { SourceActions.openInXcode(path) }
            } else if let opening, SourceOpener.xcodeURL != nil, RepositoryFileLocator.relativePath(of: path) != nil {
                if xcodeIsOpen {
                    Button("Open in Xcode") { failure = opening.open(path, file?.lineNumber) }
                } else {
                    Button("Open in Xcode", systemImage: "lock", action: showPurchase)
                        .help("Opening a file from your local clone comes with Cumulus Pro")
                }
            }
        }
    }

    private static func build(_ entry: TestHistory.Entry) -> String {
        UsageFormat.dotted([entry.number.map { "#\($0)" }, entry.date.map { UsageFormat.day($0) }, entry.shortCommit].compactMap(\.self))
    }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
        }
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// The popover's content: it reads the history when it opens, from the disk and nothing else.
struct TestHistoryPopover: View {
    let identity: TestHistory.Identity
    let access: TestHistoryAccess
    let dismiss: () -> Void
    @Environment(\.sourceOpening) private var opening
    @Environment(ProAccess.self) private var pro: ProAccess?
    @State private var history: TestHistory?
    @State private var hasRead = false

    var body: some View {
        Group {
            if hasRead, history == nil {
                Text(ProFeatureText.required).padding(16)
            } else {
                TestHistoryContent(
                    identity: identity, history: history, isReading: SkeletonRules.testHistory(hasRead: hasRead),
                    openBuild: { id in
                        dismiss()
                        access.openBuild(id)
                    },
                    opening: opening, xcodeIsOpen: pro.allows(.openInXcode),
                    showPurchase: {
                        dismiss()
                        pro?.showPurchase(for: .openInXcode)
                    }
                )
            }
        }
        .task(id: identity) {
            history = await access.tests.history(of: identity, workflowID: access.workflowID)
            hasRead = true
        }
    }
}

extension View {
    /// The history of a test in a popover anchored on this view.
    func testHistoryPopover(isPresented: Binding<Bool>, identity: TestHistory.Identity, access: TestHistoryAccess) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            TestHistoryPopover(identity: identity, access: access, dismiss: { isPresented.wrappedValue = false })
        }
    }
}

/// The small button on a test's row: the history of the test, or the way to Cumulus Pro without it.
struct TestHistoryButton: View {
    let identity: TestHistory.Identity
    let access: TestHistoryAccess
    @Environment(ProAccess.self) private var pro: ProAccess?
    @State private var isPresented = false

    var body: some View {
        let isOpen = pro.allows(.testHealth)
        Button {
            if isOpen {
                isPresented = true
            } else {
                pro?.showPurchase(for: .testHealth)
            }
        } label: {
            Image(systemName: isOpen ? "chart.bar.xaxis" : "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("History"))
        .help(isOpen ? Text("Show how this test went over the last builds") : Text("The history of a test comes with Cumulus Pro"))
        .testHistoryPopover(isPresented: $isPresented, identity: identity, access: access)
    }
}
