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
    var budgetText: String?
    /// Loaded app icons by product ID.
    var artwork: [String: AppArtwork] = [:]
    /// Pauses or resumes a workflow; nil while the key is declared read-only, and the menu then offers nothing.
    var togglePause: ((SidebarContent.Workflow) -> Void)?

    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.50percent")
                .tag(SidebarSelection.overview)
            Label("All builds", systemImage: "clock")
                .badge(content.runningCount)
                .badgeProminence(.increased)
                .tag(SidebarSelection.allBuilds)
            Label("Branches and pull requests", systemImage: "arrow.triangle.branch")
                .tag(SidebarSelection.references)

            if !content.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(content.pinned) { workflow in
                        workflowRow(workflow, showsProduct: true)
                    }
                    .onMove { pins.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            Section("Products") {
                ForEach(content.products) { product in
                    if product.workflows.isEmpty {
                        productLabel(product)
                    } else {
                        DisclosureGroup(isExpanded: expansion(of: product.id)) {
                            ForEach(product.workflows) { workflow in
                                workflowRow(workflow, showsProduct: false)
                            }
                        } label: {
                            productLabel(product)
                        }
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
                    // "Updated 2 minutes ago" is only true for a minute: the tick redraws the line, which reads the time then.
                    TickingView(interval: 60) { _ in
                        SyncActivityView(activity: activity, now: Date())
                    }
                }
                if let cycle {
                    CycleCard(fractionUsed: cycle.fractionUsed, usedText: cycle.usedText, resetText: cycle.resetText)
                } else if let setPlan {
                    CyclePromptCard(setPlan: setPlan)
                }
                if let budgetText {
                    Text(budgetText).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
            }
            .padding(10)
        }
    }

    private func productLabel(_ product: SidebarContent.Product) -> some View {
        HStack(spacing: 8) {
            AppIconView(name: product.name, swatch: product.swatch, lastStatus: product.lastStatus, artwork: artwork[product.id])
            Text(product.name)
            Spacer(minLength: 4)
            Text(product.buildCount, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(product.lastStatus.map { "\(product.name), \($0.label)" } ?? product.name)
        .accessibilityValue(Text("\(product.buildCount) builds"))
        .tag(SidebarSelection.product(product.id))
    }

    private func workflowRow(_ workflow: SidebarContent.Workflow, showsProduct: Bool) -> some View {
        Label {
            HStack {
                Text(workflow.name)
                if showsProduct {
                    Text(workflow.productName).foregroundStyle(.secondary).font(.caption)
                }
                if workflow.isPaused || workflow.isOnOlderXcode {
                    Spacer(minLength: 4)
                }
                if workflow.isOnOlderXcode {
                    Image(systemName: "arrow.up.circle").foregroundStyle(BuildStatus.errored.tint).help("Builds with an older Xcode")
                }
                if workflow.isPaused {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.secondary).help("Paused")
                }
            }
        } icon: {
            Image(systemName: pins.isPinned(workflow.id) ? "pin.fill" : "arrow.triangle.branch")
        }
        .opacity(workflow.isPaused ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text([workflow.isPaused ? String(localized: "Paused") : nil, workflow.isOnOlderXcode ? String(localized: "Builds with an older Xcode") : nil].compactMap(\.self).joined(separator: ", ")))
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

    private func expansion(of productID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(productID) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(productID) } else { collapsed.insert(productID) }
            }
        )
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
            fractionUsed = summary.fractionUsed
            usedText = String(localized: "\(UsageFormat.minutes(summary.usedMinutes)) of \(summary.plan.hours) h")
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
