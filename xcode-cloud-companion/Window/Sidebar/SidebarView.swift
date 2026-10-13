import SwiftUI

/// The left column: fixed entries, pinned workflows, then every product with its workflows, and the cycle at the foot.
struct SidebarView: View {
    let content: SidebarContent
    @Bindable var pins: PinnedWorkflows
    @Binding var selection: SidebarSelection
    let cycle: CycleCard.Content?
    /// Opens Settings on the plan; set while the account has no reset date, which is why there is no cycle to show.
    var setPlan: (() -> Void)?
    /// What the app is fetching, or how fresh the data is: shown above the cycle.
    var activity: SyncActivity?
    /// Another account's first fetch or measure, named, above the line of the account on screen.
    var backgroundActivity: (name: String, activity: SyncActivity)?
    /// The hour's requests left, in a few words for the foot and in full for its tooltip.
    var budgetText: String?
    var budgetHelp: String?
    /// Loaded app icons by product ID.
    var artwork: [String: AppArtwork] = [:]
    /// Pauses or resumes a workflow; nil while the key is declared read-only, and the menu then offers nothing.
    var togglePause: ((SidebarContent.Workflow) -> Void)?
    /// Gives an app a colour, nil for its icon's; and opens the colour panel for any other colour.
    var chooseColor: ((SidebarContent.Product, AppPalette.Choice?) -> Void)?
    var pickOtherColor: ((SidebarContent.Product) -> Void)?

    var body: some View {
        List(selection: $selection) {
            Group {
                if let cycle {
                    CycleCard(fractionUsed: cycle.fractionUsed, usedText: cycle.usedText, resetText: cycle.resetText)
                } else if let setPlan {
                    CyclePromptCard(setPlan: setPlan)
                }
            }
            // Room under the card: the first entry of the list must not sit against it.
            .padding(.bottom, 12)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .selectionDisabled()

            Label("Overview", systemImage: "gauge.with.dots.needle.50percent")
                .tag(SidebarSelection.overview)
            HStack {
                Label("All builds", systemImage: "clock")
                Spacer(minLength: 4)
                if content.runningCount > 0 {
                    StatusDot(status: .running)
                        .padding(.trailing, 4)
                        .help(Text("Builds running: \(content.runningCount)"))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(content.runningCount > 0 ? Text("Builds running: \(content.runningCount)") : Text(verbatim: ""))
            .tag(SidebarSelection.allBuilds)
            Label("Branches and pull requests", systemImage: "arrow.triangle.branch")
                .tag(SidebarSelection.references)

            if !content.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(content.pinned) { workflow in
                        workflowRow(workflow, isPinnedRow: true)
                    }
                    .onMove { pins.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            Section("Products") {
                // Always unfolded: a workflow's state is what the sidebar is read for.
                ForEach(content.products) { product in
                    productLabel(product)
                    ForEach(product.workflows) { workflow in
                        workflowRow(workflow, isPinnedRow: false)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let backgroundActivity {
                    SyncActivityView(activity: backgroundActivity.activity, now: Date(), accountName: backgroundActivity.name)
                }
                if let activity {
                    footLine(activity)
                }
            }
            .padding(10)
        }
    }

    /// One line: how fresh the builds are, and the hour's requests when there is room. While builds are measured the
    /// line is a card of its own, as before.
    @ViewBuilder
    private func footLine(_ activity: SyncActivity) -> some View {
        // "Updated 2 minutes ago" is only true for a minute: the tick redraws the line, which reads the time then.
        let line = TickingView(interval: 60) { _ in
            SyncActivityView(activity: activity, now: Date())
        }
        if case .measuring = activity {
            line
        } else if let budgetText {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    line.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    Text(budgetText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).padding(.trailing, 4)
                }
                line
            }
            .help(budgetHelp ?? budgetText)
        } else {
            line
        }
    }

    private func productLabel(_ product: SidebarContent.Product) -> some View {
        HStack(spacing: 8) {
            AppIconView(name: product.name, swatch: product.swatch, artwork: artwork[product.id])
            Text(product.name).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 4)
            Text(product.buildCount, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(product.name)
        .accessibilityValue(Text("\(product.buildCount) builds"))
        .tag(SidebarSelection.product(product.id))
        .contextMenu {
            if let chooseColor, let pickOtherColor {
                AppColorMenu(
                    choice: product.colorChoice, defaultSwatch: product.defaultSwatch, hasIconColor: product.hasIconColor,
                    choose: { chooseColor(product, $0) }, pickOther: { pickOtherColor(product) }
                )
            }
        }
    }

    /// A workflow carries the state of its last build; under its app it is indented, among the pinned it names its app.
    private func workflowRow(_ workflow: SidebarContent.Workflow, isPinnedRow: Bool) -> some View {
        HStack(spacing: 8) {
            if isPinnedRow {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            StatusDot(status: workflow.lastStatus)
            Text(workflow.name).lineLimit(1)
            if isPinnedRow {
                Text(workflow.productName).foregroundStyle(.secondary).font(.caption).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if workflow.isOnOlderXcode {
                Image(systemName: "arrow.up.circle").foregroundStyle(BuildStatus.errored.tint).help("Builds with an older Xcode")
            }
            if workflow.isPaused {
                Text("paused", comment: "Beside a workflow of the sidebar that Apple says is paused. Lowercase, very short.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.leading, isPinnedRow ? 0 : 30)
        .opacity(workflow.isPaused ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPinnedRow ? UsageFormat.dotted([workflow.name, workflow.productName]) : workflow.name)
        .accessibilityValue(Text([
            workflow.lastStatus?.label ?? String(localized: "No build yet"),
            workflow.isPaused ? String(localized: "Paused") : nil,
            workflow.isOnOlderXcode ? String(localized: "Builds with an older Xcode") : nil,
        ].compactMap(\.self).joined(separator: ", ")))
        .tag(SidebarSelection.workflow(workflow.id))
        .contextMenu {
            Button(pins.isPinned(workflow.id) ? "Unpin" : "Pin") { pins.toggle(workflow.id) }
            if let togglePause, let isEnabled = workflow.isEnabled {
                Divider()
                if workflow.isLocked {
                    // The reason stands where the action would be.
                    Button("Locked in App Store Connect: can’t be paused here") {}.disabled(true)
                } else {
                    Button(isEnabled ? "Pause…" : "Resume…") { togglePause(workflow) }
                }
            }
        }
    }
}

extension CycleCard {
    struct Content: Equatable {
        let fractionUsed: Double
        let usedText: String
        let resetText: String

        init(fractionUsed: Double, usedText: String, resetText: String) {
            self.fractionUsed = fractionUsed
            self.usedText = usedText
            self.resetText = resetText
        }

        init?(summary: UsageSummary?) {
            guard let summary, !summary.measurement.isMeasuring else { return nil }
            fractionUsed = summary.writtenFractionUsed
            usedText = String(
                localized: "\(UsageFormat.minutes(summary.usedMinutes)) of \(UsageFormat.minutes(summary.quotaMinutes))",
                comment: "Cycle card of the sidebar: the compute time used, then the plan, such as “13 hr, 37 min of 25 hr”"
            )
            resetText = String(localized: "Resets \(UsageFormat.day(summary.resetDate))")
        }
    }
}

#Preview("Barre latérale") {
    @Previewable @State var selection = SidebarSelection.allBuilds
    let products = [
        CIProduct(id: "a", name: "realmotivation", productType: "APP", appID: "1", appName: nil, bundleID: nil),
        CIProduct(id: "b", name: "second-brain", productType: "APP", appID: "2", appName: nil, bundleID: nil),
    ]
    var release = CIWorkflow(id: "w1", name: "Release", testDestinationCounts: [])
    release.productID = "a"
    var main = CIWorkflow(id: "w2", name: "Main", testDestinationCounts: [])
    main.productID = "a"
    let run = CIBuildRun(
        id: "r1", productID: "a", number: 41, createdDate: Date(), startedDate: Date(), finishedDate: nil, executionProgress: .running,
        completionStatus: nil, startReason: nil, workflowID: "w1", workflowName: "Release", sourceBranchOrTag: nil
    )
    let snapshot = BuildSnapshot(products: products, runs: [run], workflows: [release, main])
    return SidebarView(
        content: SidebarContent(snapshot: snapshot, pinnedIDs: ["w1"], palette: AppPalette()),
        pins: PinnedWorkflows(defaults: UserDefaults(suiteName: "preview") ?? .standard),
        selection: $selection,
        cycle: CycleCard.Content(fractionUsed: 0.02, usedText: "23 min sur 25 h", resetText: "réinit. 7 nov.")
    )
    .frame(width: 260, height: 480)
}
