import SwiftUI

/// What the top of the menu says of a running build: which one, what it is doing, and when it should end.
nonisolated struct RunningBuildLine: Equatable, Sendable {
    /// Running builds the menu gives a block to; the bar and the list below count the others.
    static let limit = 3

    let runID: String
    let title: String
    let workflow: String?
    let reference: String?
    /// Elapsed over the median duration, when there is an estimate.
    let progress: Double?
    let action: String
    let endLine: String?
    let spokenEnd: String?

    init(entry: RunningBuildsETA.Entry, snapshot: BuildSnapshot, now: Date, locale: Locale = .autoupdatingCurrent) {
        let run = entry.run
        runID = run.id
        let product = snapshot.product(id: run.productID)
        title = [product.map { CIProduct.compact($0.displayName) }, run.number.map { "#\($0)" }].compactMap(\.self).joined(separator: " ")
        workflow = run.workflowName
        reference = run.isPullRequestBuild == true
            ? run.pullRequestNumber.map { String(localized: LocalizedStringResource("PR #\($0)", locale: locale, comment: "A pull request, in a build's line")) }
            : run.sourceBranchOrTag
        action = Self.action(of: run, in: snapshot, locale: locale)
        if let eta = entry.eta, let display = eta.display(at: now) {
            progress = min(0.99, eta.progress(at: now))
            endLine = BuildETAFormat.endLine(end: eta.expectedEnd, display: display, locale: locale)
            spokenEnd = BuildETAFormat.spoken(display, locale: locale)
        } else {
            progress = nil
            endLine = nil
            spokenEnd = nil
        }
    }

    /// The running builds of a snapshot, the nearest end first.
    static func lines(in snapshot: BuildSnapshot, now: Date, locale: Locale = .autoupdatingCurrent) -> [RunningBuildLine] {
        RunningBuildsETA.entries(in: snapshot, now: now).map { RunningBuildLine(entry: $0, snapshot: snapshot, now: now, locale: locale) }
    }

    /// The action under way (“Test – iOS running”); a build still in the queue says so.
    private static func action(of run: CIBuildRun, in snapshot: BuildSnapshot, locale: Locale) -> String {
        if run.executionProgress == .pending {
            return String(localized: LocalizedStringResource("Waiting to start", locale: locale, comment: "A build that Apple has not started yet"))
        }
        let current = (snapshot.actionsByRunID[run.id] ?? [])
            .filter { $0.executionProgress == .running }
            .min { ($0.startedDate ?? .distantFuture) < ($1.startedDate ?? .distantFuture) }
        guard let current else { return BuildStatus.running.label }
        return String(localized: LocalizedStringResource("\(BuildDetailModel.name(of: current)) running", locale: locale, comment: "The action a build is on, such as “Test – iOS running”"))
    }
}

/// A running build at the head of the menu. Drawn once when the menu opens: it does not move while the menu is open.
struct RunningBuildHeaderView: View {
    let line: RunningBuildLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.title).font(.headline)
                if let workflow = line.workflow {
                    Text(verbatim: "· " + workflow).foregroundStyle(.secondary).font(.caption)
                }
            }
            .lineLimit(1)
            if let reference = line.reference {
                Text(reference)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let progress = line.progress {
                HStack(spacing: 8) {
                    ProgressTrack(fraction: progress)
                    Text(verbatim: "~" + UsageFormat.percent(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.action).font(.callout)
                if let endLine = line.endLine {
                    Text(endLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: usageMenuContentWidth, idealWidth: usageMenuContentWidth, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(UsageFormat.dotted([line.title, line.workflow, line.reference, line.action].compactMap(\.self))))
        .accessibilityValue(Text(line.spokenEnd ?? ""))
    }
}

private struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(Color.blue).frame(width: geometry.size.width * fraction)
                }
            }
    }
}
