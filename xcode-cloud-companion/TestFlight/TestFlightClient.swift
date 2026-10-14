import Foundation

extension AppStoreConnectClient {
    /// The newest TestFlight builds of an app: one request, no paging.
    func testFlightBuilds(appID: String) async throws(AppStoreConnectError) -> [TestFlightBuild] {
        let page: JSONAPIDocument<TestFlightBuildAttributes> = try await document(at: AppStoreConnectEndpoint.testFlightBuilds(appID: appID))
        return page.testFlightBuilds
    }
}
