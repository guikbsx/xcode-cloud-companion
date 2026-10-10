import SwiftUI

/// On a failed build: what changed since the last build of its workflow that succeeded.
struct RegressionGroup: View {
    static let visibleEntries = 12

    let run: CIBuildRun
    let buildStore: BuildStore
    let extrasStore: BuildExtrasStore
    let openBuild: (String) -> Void

    @State private var isLoading = false
    @State private var budgetIsShort = false

    var body: some View {
        let status = BuildStatus(run: run)
        if run.executionProgress == .complete, status == .failed || status == .errored {
            let reference = RegressionReport.reference(for: run, in: buildStore.snapshot)
            VStack(alignment: .leading, spacing: 10) {
                Text("Since the last successful build")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                if let reference {
                    content(reference)
                } else {
                    Text("No earlier successful build of this workflow to compare with.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cumulusGroup()
            .task(id: [run.id, reference?.id]) {
                // What both builds already have on disk shows at once; nothing is asked of Apple here.
                await extrasStore.loadCached(run)
                if let reference { await extrasStore.loadCached(reference) }
            }
        }
    }

    @ViewBuilder
    private func content(_ reference: CIBuildRun) -> some View {
        let number = reference.number.map { "#\($0)" } ?? "#?"
        HStack(spacing: 8) {
            Button {
                openBuild(reference.id)
            } label: {
                Label(number, systemImage: "checkmark.circle.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .help("Open this build")
            if let created = reference.createdDate {
                Text(UsageFormat.moment(created)).foregroundStyle(.secondary)
            }
            if let branch = reference.sourceBranchOrTag {
                CapsuleTag(text: branch, systemImage: "arrow.triangle.branch")
            }
        }
        if let range = CommitRange(reference: reference, run: run) {
            HStack(spacing: 10) {
                Text(verbatim: "\(range.from) → \(range.to)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let url = range.url {
                    Link(range.isComparison ? String(localized: "Compare commits") : String(localized: "View commit"), destination: url)
                        .font(.callout)
                }
            }
        }

        let extras = extrasStore.extras(for: run.id)
        let referenceExtras = extrasStore.extras(for: reference.id)
        if let extras, let referenceExtras, RegressionReport.isReady(extras: extras, referenceExtras: referenceExtras) {
            report(
                RegressionReport(
                    actions: buildStore.snapshot.actionsByRunID[run.id] ?? [], extras: extras,
                    referenceActions: buildStore.snapshot.actionsByRunID[reference.id] ?? [], referenceExtras: referenceExtras
                ),
                referenceNumber: number
            )
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading the tests and issues of both builds…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            if let failure = failureMessage(reference) {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
            } else if budgetIsShort {
                Label("Too few requests left this hour to compare. Try again later.", systemImage: "hourglass")
                    .foregroundStyle(.secondary).font(.callout)
            }
            HStack(spacing: 10) {
                Button("Compare with \(number)") {
                    Task { await compare(with: reference) }
                }
                Text("Loads the tests and issues of both builds, one action at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func report(_ report: RegressionReport, referenceNumber: String) -> some View {
        if report.isEmpty {
            Text("No failing test and no new issue to tell apart from \(referenceNumber).")
                .foregroundStyle(.secondary)
        }
        tests("Tests broken by this build", report.brokenTests, tint: BuildStatus.failed.tint, systemImage: "xmark.octagon.fill")
        tests("New tests that fail", report.newFailingTests, tint: BuildStatus.errored.tint, systemImage: "plus.circle.fill")
        if !report.newIssues.isEmpty {
            section("New issues", count: report.newIssues.count) {
                ForEach(report.newIssues.prefix(Self.visibleEntries)) { issue in
                    entry(
                        title: issue.message, detail: UsageFormat.dotted([issue.type.label, issue.actionName, issue.location].compactMap(\.self).filter { !$0.isEmpty }),
                        message: nil, tint: issue.type == .error ? BuildStatus.failed.tint : BuildStatus.errored.tint, systemImage: issue.type.systemImage
                    )
                }
                more(report.newIssues.count)
            }
        }
        tests("Tests already failing in \(referenceNumber)", report.persistingTests, tint: .secondary, systemImage: "arrow.uturn.backward.circle")
    }

    @ViewBuilder
    private func tests(_ title: LocalizedStringKey, _ entries: [RegressionReport.TestEntry], tint: Color, systemImage: String) -> some View {
        if !entries.isEmpty {
            section(title, count: entries.count) {
                ForEach(entries.prefix(Self.visibleEntries)) { test in
                    entry(
                        title: [test.className, test.name].compactMap(\.self).joined(separator: "."),
                        detail: UsageFormat.dotted([test.actionName, test.location].compactMap(\.self).filter { !$0.isEmpty }),
                        message: test.message, tint: tint, systemImage: systemImage
                    )
                }
                more(entries.count)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(.top, 4)
    }

    private func entry(title: String, detail: String, message: String?, tint: Color, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).textSelection(.enabled).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func more(_ count: Int) -> some View {
        if count > Self.visibleEntries {
            Text("\(count - Self.visibleEntries) more in the tabs below").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func failureMessage(_ reference: CIBuildRun) -> String? {
        for build in [run, reference] {
            for part in [BuildExtrasStore.Part.tests, .issues] {
                if case .failed(let message, _, _) = extrasStore.state(part, runID: build.id) { return message }
            }
        }
        return nil
    }

    /// One action at a time, and not at all when the hour's requests are nearly spent.
    private func compare(with reference: CIBuildRun) async {
        isLoading = true
        defer { isLoading = false }
        for build in [run, reference] {
            await buildStore.updateRateLimit()
            if let budget = buildStore.rateLimit, budget.remaining <= SyncSchedule.criticalRemaining {
                budgetIsShort = true
                return
            }
            let actions = buildStore.snapshot.actionsByRunID[build.id] ?? []
            await extrasStore.loadTests(for: build, actions: actions)
            await extrasStore.loadIssues(for: build, actions: actions)
        }
        budgetIsShort = false
    }
}
