import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct WorkflowDetailTests {
    private let english = Locale(identifier: "en_US")

    private func fixtureWorkflow() async throws -> CIWorkflow {
        let transport = MockTransport { _ in
            MockTransport.Reply(status: 200, body: (try? Fixture.data("ciWorkflowDetails")) ?? Data(), headers: [:])
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return try #require(try await client.workflowDetails(productID: "p").first)
    }

    @Test func theSheetReadsTheConfigurationInWords() async throws {
        let model = WorkflowDetailModel(workflow: try await fixtureWorkflow(), productName: "realmotivation", locale: english)

        #expect(model.title == "Public archive (with test)")
        #expect(model.isEnabled == true && model.isLocked == false)
        #expect(model.info.map(\.title) == ["Clean build", "Project", "Repository", "Xcode", "macOS", "Last modified"])
        #expect(model.info[0].value == "No")
        #expect(model.info[2].value == "guikbsx/realmotivation")
        #expect(model.startConditions.map(\.title) == ["Branch changes", "Schedule", "Files and folders", "Auto-cancel", "Manual start"])
        #expect(model.startConditions[0].value == "develop, release/")
        #expect(model.startConditions[1].value == "Every week")
        #expect(model.startConditions[3].value == "On")
    }

    @Test func actionsListTheirPlatformDestinationAndAudience() async throws {
        let model = WorkflowDetailModel(workflow: try await fixtureWorkflow(), productName: nil, locale: english)

        #expect(model.actions.map(\.kind) == ["Build", "Test", "Archive"])
        #expect(model.actions[0].facts.hasPrefix("iOS"))
        #expect(model.actions[2].facts.contains("TestFlight and App Store"))
    }

    @Test func aWorkflowKnownOnlyByItsNameShowsNothingElse() {
        let model = WorkflowDetailModel(workflow: CIWorkflow(id: "w", name: "Main", testDestinationCounts: []), productName: nil, locale: english)

        #expect(model.info.isEmpty && model.startConditions.isEmpty && model.actions.isEmpty)
        #expect(model.isEnabled == nil && model.description == nil)
    }

    // MARK: - Store

    private func transport() -> MockTransport {
        MockTransport { _ in
            MockTransport.Reply(status: 200, body: (try? Fixture.data("ciWorkflowDetails")) ?? Data(), headers: [:])
        }
    }

    private func store(_ directory: URL, _ transport: MockTransport, now: @escaping () -> Date) -> WorkflowDetailStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return WorkflowDetailStore(cache: WorkflowDetailsCache(directory: directory), client: { client }, now: now)
    }

    @Test func aFreshCachedCopyIsUsedWithoutAskingAndAStaleOneIsRefreshed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "workflows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()
        let start = Date(timeIntervalSince1970: 1_791_000_000)

        let first = store(directory, transport, now: { start })
        await first.load(productID: "p")
        let second = store(directory, transport, now: { start.addingTimeInterval(600) })
        await second.load(productID: "p")
        let third = store(directory, transport, now: { start.addingTimeInterval(7200) })
        await third.load(productID: "p")

        #expect(await transport.requests.count == 2)
        #expect(second.workflow(id: first.workflowsByID.keys.first ?? "")?.name == "Public archive (with test)")
        #expect(first.workflowsByID.values.allSatisfy { $0.productID == "p" })
    }

    @Test func pickingSomethingElseInTheSidebarClearsTheBuildButOpeningABuildKeepsIt() {
        let navigation = NavigationModel()
        navigation.selectedBuildID = "run"

        navigation.sidebarSelection = .workflow("w")
        #expect(navigation.selectedBuildID == nil)

        navigation.showBuild("run-2")
        #expect(navigation.selectedBuildID == "run-2")
        #expect(navigation.sidebarSelection == .allBuilds)
    }
}
