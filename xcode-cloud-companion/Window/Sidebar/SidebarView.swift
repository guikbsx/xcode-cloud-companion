import SwiftUI

/// The left column: fixed entries, pinned workflows, then every product with its workflows, and the cycle at the foot.
struct SidebarView: View {
    let content: SidebarContent
    @Bindable var pins: PinnedWorkflows
    @Binding var selection: SidebarSelection
    let cycle: CycleCard.Content?
    var budgetText: String?

    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.50percent")
                .tag(SidebarSelection.overview)
            Label("All builds", systemImage: "clock")
                .badge(content.runningCount)
                .badgeProminence(.increased)
                .tag(SidebarSelection.allBuilds)

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
                if let cycle {
                    CycleCard(fractionUsed: cycle.fractionUsed, usedText: cycle.usedText, resetText: cycle.resetText)
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
            AppIconView(name: product.name, swatch: product.swatch, lastStatus: product.lastStatus)
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
            }
        } icon: {
            Image(systemName: pins.isPinned(workflow.id) ? "pin.fill" : "arrow.triangle.branch")
        }
        .tag(SidebarSelection.workflow(workflow.id))
        .contextMenu {
            Button(pins.isPinned(workflow.id) ? "Unpin" : "Pin") { pins.toggle(workflow.id) }
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
