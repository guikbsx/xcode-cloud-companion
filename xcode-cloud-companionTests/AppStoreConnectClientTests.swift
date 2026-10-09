import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AppStoreConnectClientTests {
    private static let start = Date(timeIntervalSince1970: 1_791_500_000)

    private static func buildRunPages(_ request: URLRequest) -> MockTransport.Reply {
        let name = request.queryValue("cursor") == nil ? "ciBuildRuns-page1" : "ciBuildRuns-page2"
        return MockTransport.Reply(body: (try? Fixture.data(name)) ?? Data())
    }

    @Test func requestsAreAuthenticatedAndAskOnlyForUsefulFields() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let products = try await client.products()

        #expect(products.count == 2)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host() == "api.appstoreconnect.apple.com")
        #expect(request.url?.path() == "/v1/ciProducts")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.queryValue("include") == "app")
        #expect(request.queryValue("fields[apps]") == "name,bundleId")
        #expect(request.queryValue("limit") == "200")
    }

    @Test func buildRunsAreFetchedNewestFirstWithTheirWorkflowAndBranch() async throws {
        let transport = MockTransport(reply: Self.buildRunPages)
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        _ = try await client.buildRuns(productID: "product-1", maxPages: 1)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/v1/ciProducts/product-1/buildRuns")
        #expect(request.queryValue("sort") == "-number")
        #expect(request.queryValue("include") == "workflow,sourceBranchOrTag")
        #expect(request.queryValue("fields[ciWorkflows]") == "name")
    }

    @Test func paginationFollowsNextLinks() async throws {
        let transport = MockTransport(reply: Self.buildRunPages)
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let runs = try await client.buildRuns(productID: "product-1")

        #expect(runs.map(\.number) == [42, 41, 40, 39])
        #expect(await transport.requests.count == 2)
    }

    @Test func paginationStopsAtThePageLimit() async throws {
        let transport = MockTransport(reply: Self.buildRunPages)
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let runs = try await client.buildRuns(productID: "product-1", maxPages: 1)

        #expect(runs.map(\.number) == [42, 41])
        #expect(await transport.requests.count == 1)
    }

    @Test func paginationStopsOnceBuildsAreOlderThanTheWindow() async throws {
        let transport = MockTransport(reply: Self.buildRunPages)
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let september1 = Date(timeIntervalSince1970: 1_788_220_800)
        let october8 = Date(timeIntervalSince1970: 1_791_417_600)

        let sinceSeptember = try await client.buildRuns(productID: "product-1", createdSince: september1)
        #expect(sinceSeptember.map(\.number) == [42, 41, 40])
        #expect(await transport.requests.count == 2)

        let sinceOctober8 = try await client.buildRuns(productID: "product-1", createdSince: october8)
        #expect(sinceOctober8.map(\.number) == [42])
        #expect(await transport.requests.count == 3)
    }

    @Test func nextLinksOutsideApplesAPIAreRefused() async throws {
        let page = """
        {"data": [], "links": {"next": "https://example.com/steal?cursor=1"}}
        """
        let transport = MockTransport { _ in MockTransport.Reply(body: Data(page.utf8)) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect(throws: AppStoreConnectError.invalidResponse) {
            try await client.products()
        }
        #expect(await transport.requests.allSatisfy { $0.url?.host() == "api.appstoreconnect.apple.com" })
    }

    @Test func buildActionsAreAttachedToTheirBuildRun() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciBuildActions")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let actions = try await client.buildActions(buildRunID: "run-41")

        #expect(actions.count == 2)
        #expect(actions.allSatisfy { $0.buildRunID == "run-41" })
        #expect(await transport.requests.first?.url?.path() == "/v1/ciBuildRuns/run-41/actions")
    }

    @Test(arguments: [
        (401, AppStoreConnectError.unauthorized(status: 401)),
        (403, AppStoreConnectError.unauthorized(status: 403)),
        (429, AppStoreConnectError.rateLimited),
        (500, AppStoreConnectError.server(status: 500, detail: "An unexpected error occurred on the server side.")),
    ])
    func httpErrorsAreTyped(status: Int, expected: AppStoreConnectError) async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: status, body: (try? Fixture.data("errorResponse")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect(throws: expected) {
            try await client.products()
        }
    }

    @Test func networkFailuresAreTyped() async {
        let transport = MockTransport { _ in MockTransport.Reply(error: URLError(.notConnectedToInternet)) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect(throws: AppStoreConnectError.network(.notConnectedToInternet)) {
            try await client.products()
        }
    }

    @Test func malformedBodiesAreDecodingErrors() async {
        let transport = MockTransport { _ in MockTransport.Reply(body: Data("{".utf8)) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        await #expect {
            try await client.products()
        } throws: { error in
            if case .decoding = error as? AppStoreConnectError { true } else { false }
        }
    }

    @Test func tokenIsReusedUntilItNearsExpiry() async throws {
        let clock = TestClock(Self.start)
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciProducts")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport, now: { clock.now })

        _ = try await client.products()
        clock.advance(by: 10 * 60)
        _ = try await client.products()
        clock.advance(by: 9 * 60)
        _ = try await client.products()

        let tokens = await transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens[0] == tokens[1])
        #expect(tokens[1] != tokens[2])
    }
}
