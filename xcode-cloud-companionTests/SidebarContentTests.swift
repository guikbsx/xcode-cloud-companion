import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct SidebarContentTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func run(
        _ number: Int, product: String, workflow: String?, minutesAgo: Double, progress: CIExecutionProgress = .complete,
        status: CICompletionStatus? = .succeeded
    ) -> CIBuildRun {
        let created = now.addingTimeInterval(-minutesAgo * 60)
        return CIBuildRun(
            id: "run-\(product)-\(number)", productID: product, number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(600) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: workflow, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func workflow(_ id: String, _ name: String, product: String? = nil) -> CIWorkflow {
        var workflow = CIWorkflow(id: id, name: name, testDestinationCounts: [])
        workflow.productID = product
        return workflow
    }

    private var snapshot: BuildSnapshot {
        BuildSnapshot(
            products: [
                CIProduct(id: "a", name: "Alpha", productType: "APP", appID: "1", appName: nil, bundleID: nil),
                CIProduct(id: "b", name: "Beta", productType: "APP", appID: "2", appName: nil, bundleID: nil),
                CIProduct(id: "c", name: "Gamma", productType: "APP", appID: "3", appName: nil, bundleID: nil),
            ],
            runs: [
                run(1, product: "a", workflow: "wa-release", minutesAgo: 600),
                run(2, product: "a", workflow: "wa-beta", minutesAgo: 500, status: .failed),
                run(3, product: "b", workflow: "wb", minutesAgo: 10, progress: .running),
                run(4, product: "b", workflow: "wb", minutesAgo: 300),
            ],
            workflows: [
                workflow("wa-release", "Release", product: "a"), workflow("wa-beta", "Beta", product: "a"),
                workflow("wb", "Main"),
            ]
        )
    }

    @Test func productsComeNewestActivityFirstWithTheirWorkflowsByName() {
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())

        #expect(content.products.map(\.name) == ["Beta", "Alpha", "Gamma"])
        #expect(content.products[1].workflows.map(\.name) == ["Beta", "Release"])
        #expect(content.products.map(\.buildCount) == [2, 2, 0])
    }

    @Test func aWorkflowWithoutProductIsPlacedThroughItsBuilds() {
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())

        #expect(content.products[0].workflows.map(\.id) == ["wb"])
        #expect(content.products[0].workflows.first?.buildCount == 2)
    }

    @Test func aProductWithoutWorkflowsIsStillListed() {
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())

        let gamma = content.products.last
        #expect(gamma?.name == "Gamma")
        #expect(gamma?.workflows.isEmpty == true)
        #expect(gamma?.lastStatus == nil)
    }

    @Test func theLastBuildGivesTheProductItsStatusAndTheRunningOnesAreCounted() {
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: [], palette: AppPalette())

        #expect(content.products[0].lastStatus == .running)
        #expect(content.products[1].lastStatus == .failed)
        #expect(content.runningCount == 1)
    }

    @Test func pinnedWorkflowsKeepTheUsersOrderAndForgetTheOnesThatVanished() {
        let content = SidebarContent(snapshot: snapshot, pinnedIDs: ["wb", "gone", "wa-release"], palette: AppPalette())

        #expect(content.pinned.map(\.id) == ["wb", "wa-release"])
        #expect(content.pinned.first?.productName == "Beta")
    }

    @Test func pinsAreSavedAndReordered() throws {
        let suite = "PinnedWorkflowsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let pins = PinnedWorkflows(defaults: defaults)
        pins.toggle("one")
        pins.toggle("two")
        pins.toggle("three")
        pins.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        pins.toggle("two")

        #expect(PinnedWorkflows(defaults: defaults).ids == ["three", "one"])
        #expect(pins.isPinned("one") && !pins.isPinned("two"))
    }
}
