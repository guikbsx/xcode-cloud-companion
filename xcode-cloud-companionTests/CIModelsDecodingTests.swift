import Foundation
import Testing
@testable import XcodeCloudCompanion

struct CIModelsDecodingTests {
    @Test func productsCarryTheirIncludedApp() throws {
        let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIProductAttributes>.self, from: Fixture.data("ciProducts"))

        #expect(document.products == [
            CIProduct(id: "product-1", name: "Sample App", productType: "APP", appID: "app-1", appName: "Sample App Store Name", bundleID: "com.example.sample"),
            CIProduct(id: "product-2", name: "Sample Framework", productType: "FRAMEWORK", appID: nil, appName: nil, bundleID: nil),
        ])
    }

    @Test func buildRunsResolveWorkflowAndBranchNames() throws {
        let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildRunAttributes>.self, from: Fixture.data("ciBuildRuns-page1"))
        let runs = document.buildRuns(productID: "product-1")

        let running = try #require(runs.first)
        #expect(running.id == "run-42")
        #expect(running.productID == "product-1")
        #expect(running.number == 42)
        #expect(running.executionProgress == .running)
        #expect(running.completionStatus == nil)
        #expect(running.finishedDate == nil)
        #expect(running.workflowName == "Release")
        #expect(running.sourceBranchOrTag == "main")
        #expect(document.links?.next?.query()?.contains("cursor=Mg") == true)
    }

    @Test func datesAcceptFractionalSecondsAndOffsets() throws {
        let page1 = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildRunAttributes>.self, from: Fixture.data("ciBuildRuns-page1"))
        let page2 = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildRunAttributes>.self, from: Fixture.data("ciBuildRuns-page2"))
        let runs = page1.buildRuns(productID: "p") + page2.buildRuns(productID: "p")

        let fractional = try #require(runs[0].createdDate).timeIntervalSince1970
        #expect(abs(fractional - 1_791_460_800.123) < 0.001)
        #expect(runs[1].createdDate == Date(timeIntervalSince1970: 1_791_374_400))
        #expect(runs[1].finishedDate?.timeIntervalSince(try #require(runs[1].startedDate)) == 20 * 60)
        #expect(runs[2].createdDate == Date(timeIntervalSince1970: 1_789_898_400))
    }

    @Test func unknownStatusesAreKeptRatherThanRejected() throws {
        let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildRunAttributes>.self, from: Fixture.data("ciBuildRuns-page2"))
        let runs = document.buildRuns(productID: "product-1")

        #expect(runs[0].completionStatus == .succeeded)
        #expect(runs[1].completionStatus == .unknown("SOMETHING_NEW"))
        #expect(runs[1].workflowName == "Pull Requests")
        #expect(runs[1].sourceBranchOrTag == nil)
    }

    @Test func buildActionsKeepTheirTypeAndTiming() throws {
        let document = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<CIBuildActionAttributes>.self, from: Fixture.data("ciBuildActions"))
        let actions = document.buildActions(buildRunID: "run-41")

        #expect(actions.map(\.actionType) == [.test, .archive])
        #expect(actions.map(\.completionStatus) == [.failed, .succeeded])
        #expect(actions.allSatisfy { $0.buildRunID == "run-41" && $0.isRequiredToPass == true })
        let archive = try #require(actions.last)
        #expect(archive.finishedDate?.timeIntervalSince(try #require(archive.startedDate)) == 15 * 60 + 30)
    }
}
