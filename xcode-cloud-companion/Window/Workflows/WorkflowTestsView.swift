import SwiftUI

/// The Tests section of a workflow sheet: flaky tests, then the slowest ones, over the builds already analyzed.
struct WorkflowTestsSection: View {
    let workflowID: String
    let model: WorkflowTestsModel
    /// Opens a build on its Tests tab.
    let openBuild: (String) -> Void

    var body: some View {
        // The report is read from the disk: until it is, the section stands as a skeleton of itself.
        let report = model.report ?? .placeholder
        VStack(alignment: .leading, spacing: 12) {
            Text("Tests")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            coverage(report)
            if report.analyzedBuilds > 0 {
                flaky(report)
                slowest(report)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
        .skeleton(model.report == nil)
        .task(id: workflowID) { await model.refresh(workflowID: workflowID) }
    }

    @ViewBuilder
    private func coverage(_ report: TestHealthReport) -> some View {
        Text("Builds analyzed: \(report.analyzedBuilds) of \(report.eligibleBuilds). Only builds whose test results were loaded count, among the finished builds Cumulus keeps (about a month).")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let progress = model.progress {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(maxWidth: 200)
                Text("Analyzing build \(min(progress.done + 1, progress.total)) of \(progress.total)…").font(.caption).foregroundStyle(.secondary)
                Button("Stop") { model.stop() }
            }
        } else {
            let remaining = min(WorkflowTestsModel.batchSize, report.eligibleBuilds - report.analyzedBuilds)
            if remaining > 0 {
                HStack(spacing: 10) {
                    Button("Analyze More Builds (\(remaining))") { model.startAnalysis(workflowID: workflowID) }
                    Text("The latest first, one action at a time. You can stop at any moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if model.stoppedForBudget {
            Label("Stopped: too few requests left this hour. Try again later.", systemImage: "hourglass")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let failure = model.failureMessage {
            Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(BuildStatus.errored.tint)
        }
    }

    @ViewBuilder
    private func flaky(_ report: TestHealthReport) -> some View {
        Text("Flaky tests").fontWeight(.semibold).padding(.top, 4)
        if report.flaky.isEmpty {
            Text("No flaky test in the builds analyzed.").foregroundStyle(.secondary)
        }
        ForEach(report.flaky) { test in
            Button {
                openBuild(test.lastFailureRunID)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dice").foregroundStyle(BuildStatus.errored.tint).font(.caption).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([test.className, test.name].compactMap(\.self).joined(separator: ".")).font(.callout).lineLimit(2)
                        Text(Self.facts(of: test)).font(.caption).foregroundStyle(.secondary)
                        if !test.devices.isEmpty {
                            Text(test.devices.formatted(.list(type: .and, width: .narrow))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the last build where it failed, on its Tests tab"))
            .help("Open the last build where it failed")
        }
    }

    @ViewBuilder
    private func slowest(_ report: TestHealthReport) -> some View {
        if !report.slowest.isEmpty {
            Text("Slowest tests").fontWeight(.semibold).padding(.top, 4)
            ForEach(report.slowest) { test in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary).font(.caption).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([test.className, test.name].compactMap(\.self).joined(separator: ".")).font(.callout).lineLimit(2)
                        Text(UsageFormat.dotted([
                            String(localized: "\(Self.duration(test.averageSecondsPerDevice)) per device on average"),
                            String(localized: "\(UsageFormat.percent(test.share)) of the test time"),
                            test.actionName,
                        ].filter { !$0.isEmpty }))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func facts(of test: TestHealthReport.FlakyTest) -> String {
        var parts = [String(localized: "Failures: \(test.failures) / \(test.runs)", comment: "Failures of a test over the builds where it ran")]
        let last = UsageFormat.dotted([test.lastFailureNumber.map { "#\($0)" }, test.lastFailureDate.map { UsageFormat.day($0) }].compactMap(\.self))
        if !last.isEmpty {
            parts.append(String(localized: "Last failure: \(last)"))
        }
        if test.differsBetweenDevices {
            parts.append(String(localized: "Differs between devices"))
        }
        if test.flipsOnSameCommit {
            parts.append(String(localized: "Fails and passes on the same commit"))
        }
        return UsageFormat.dotted(parts)
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
