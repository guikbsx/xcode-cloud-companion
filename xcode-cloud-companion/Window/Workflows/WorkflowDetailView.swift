import SwiftUI

/// The sheet of a workflow: how it starts, where it runs, what it does. Read only.
struct WorkflowDetailView: View {
    let model: WorkflowDetailModel
    var tests: WorkflowTestsModel?
    /// The workflow's own details are on their way: the facts, the description and the conditions stand as skeletons.
    var isLoading = false
    var openBuildTests: (String) -> Void = { _ in }
    /// How the workflow's builds go over time, from the cache; nil leaves the section out.
    var trends: WorkflowTrends?
    /// Since which build the workflow got slower, with its cause; nil when it did not.
    var slowdown: WorkflowSlowdownModel?
    var openBuild: (String) -> Void = { _ in }
    /// Pauses or resumes this workflow; nil while the key is declared read-only.
    var togglePause: (() -> Void)?
    /// Set when the workflow builds with an Xcode older than the newest public one.
    var xcodeWarning: XcodeVersionCheck.Warning?
    /// Opens the sheet that changes the workflow; nil shows the way to App Store Connect instead.
    var editWorkflow: (() -> Void)?
    var workflowURL: URL?
    @Environment(ProAccess.self) private var access: ProAccess?

    var body: some View {
        DetailScroll { columns in
            // What the workflow is set to do goes beside what its builds say; with nothing about its builds, it stays under the header.
            let isSplit = columns == .two && (tests != nil || trends != nil)
            let configuration = isSplit ? DetailPlacement.side : .main
            if let xcodeWarning {
                xcodeBanner(xcodeWarning)
                    .detailPlacement(.full)
            }
            header
                .accessibilitySortPriority(isSplit ? 1 : 0)
            let showsFactsSkeleton = isLoading && model.info.isEmpty
            let showsConditionsSkeleton = isLoading && model.startConditions.isEmpty
            if !model.info.isEmpty || showsFactsSkeleton {
                LazyVGrid(columns: isSplit ? Self.pairedFacts : Self.flowingFacts, alignment: .leading, spacing: 14) {
                    ForEach(showsFactsSkeleton ? WorkflowDetailModel.placeholderInfo : model.info) { InfoItem(key: $0.title, value: $0.value, help: $0.help) }
                }
                .cumulusGroup()
                .skeleton(showsFactsSkeleton)
                .detailPlacement(configuration)
            }
            if !model.startConditions.isEmpty || showsConditionsSkeleton {
                section("Start conditions") {
                    ForEach(showsConditionsSkeleton ? WorkflowDetailModel.placeholderConditions : model.startConditions) { condition in
                        // The value beside its title; under it when it is too long for the line.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(condition.title).fontWeight(.semibold).lineLimit(1).fixedSize().unredacted()
                                Spacer(minLength: 12)
                                Text(condition.value).foregroundStyle(.secondary).lineLimit(1).fixedSize().textSelection(.enabled)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(condition.title).fontWeight(.semibold).unredacted()
                                Text(condition.value).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .skeleton(showsConditionsSkeleton)
                .detailPlacement(configuration)
            }
            if !model.actions.isEmpty {
                section("Actions") {
                    ForEach(model.actions) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.name).fontWeight(.semibold)
                            if !action.facts.isEmpty {
                                Text(action.facts).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .detailPlacement(configuration)
            }
            if let tests {
                Group {
                    if access.allows(.testHealth) {
                        WorkflowTestsSection(workflowID: model.id, model: tests, openBuild: openBuildTests)
                    } else {
                        ProLockedCard(feature: .testHealth)
                    }
                }
                .accessibilitySortPriority(isSplit ? 1 : 0)
            }
            if let trends {
                Group {
                    if access.allows(.workflowTrends) {
                        WorkflowTrendsSection(trends: trends, slowdown: slowdown, openBuild: openBuild)
                    } else {
                        ProLockedCard(feature: .workflowTrends)
                    }
                }
                .accessibilitySortPriority(isSplit ? 1 : 0)
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.productName ?? "")
    }

    private static let flowingFacts = [GridItem(.adaptive(minimum: 170), alignment: .topLeading)]
    /// Two facts per line, in the side column.
    private static let pairedFacts = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.system(size: 30, weight: .bold, design: .rounded))
            HStack(spacing: 6) {
                if let isEnabled = model.isEnabled {
                    CapsuleTag(
                        text: isEnabled ? String(localized: "Enabled") : String(localized: "Paused"),
                        systemImage: isEnabled ? "checkmark" : "pause",
                        tint: isEnabled ? BuildStatus.succeeded.tint : BuildStatus.skipped.tint
                    )
                }
                if model.isLocked == true {
                    CapsuleTag(text: String(localized: "Locked"), systemImage: "lock")
                }
                if let togglePause, let isEnabled = model.isEnabled, model.isLocked != true {
                    Button(isEnabled ? "Pause…" : "Resume…", systemImage: isEnabled ? "pause.fill" : "play.fill", action: togglePause)
                        .controlSize(.small)
                        .padding(.leading, 6)
                }
                if let editWorkflow {
                    Button("Change…", systemImage: "pencil", action: editWorkflow)
                        .controlSize(.small)
                }
            }
            if togglePause != nil, model.isLocked == true {
                Text(WorkflowPauser.lockedMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let description = model.description {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            } else if isLoading {
                Text(WorkflowDetailModel.placeholderDescription).foregroundStyle(.secondary).skeleton(true)
            }
        }
    }

    private func xcodeBanner(_ warning: XcodeVersionCheck.Warning) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).accessibilityHidden(true)
            Text("This workflow stays on \(warning.current). \(warning.latest) is available on Xcode Cloud.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let editWorkflow {
                Button("Change…", action: editWorkflow).controlSize(.small)
            } else if let workflowURL {
                Button("Open in App Store Connect") { NSWorkspace.shared.open(workflowURL) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(BuildStatus.errored.tint.opacity(0.12), in: .rect(cornerRadius: CumulusStyle.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }
}
