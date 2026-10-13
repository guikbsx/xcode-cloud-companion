import Foundation
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct OlderBuildsTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func store(status: Int = 200) -> (OlderBuildsStore, MockTransport) {
        let transport = MockTransport { request in
            guard status == 200 else { return MockTransport.Reply(status: status, body: Data(), headers: [:]) }
            let fixture = request.queryValue("cursor") == nil ? "ciBuildRuns-page1" : "ciBuildRuns-page2"
            return MockTransport.Reply(body: (try? Fixture.data(fixture)) ?? Data())
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return (OlderBuildsStore(client: { client }, budget: { nil }), transport)
    }

    private func firstPage() async throws -> [CIBuildRun] {
        let client = AppStoreConnectClient(credentials: .sample(), transport: MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciBuildRuns-page1")) ?? Data()) })
        let page: JSONAPIDocument<CIBuildRunAttributes> = try await client.document(at: AppStoreConnectEndpoint.buildRuns(productID: "product-1", pageSize: 50))
        return page.buildRuns(productID: "product-1")
    }

    @Test func thePagesAfterTheCacheAreReadOneClickAtATimeUntilTheLast() async throws {
        let (store, transport) = store()
        let known = try await firstPage()

        await store.loadOlder(productID: "product-1", known: known)

        #expect(!store.runs.isEmpty && store.runs.allSatisfy { run in !known.contains { $0.id == run.id } }, "only builds the cache does not hold")
        #expect(store.isExhausted("product-1"), "the second page is the last")
        #expect(await transport.requests.count == 2, "the first page repeats the cache: the next one is read in the same click")

        await store.loadOlder(productID: "product-1", known: known)
        #expect(await transport.requests.count == 2, "nothing more to read")
    }

    @Test func aRateLimitStopsTheReadingAndIsNotRetried() async throws {
        let (store, transport) = store(status: 429)

        await store.loadOlder(productID: "product-1", known: [])

        #expect(store.runs.isEmpty && store.lastError != nil && !store.isExhausted("product-1"))
        #expect(await transport.requests.count == 1)
    }

    @Test func olderBuildsJoinTheListWithoutDuplicatingTheCache() {
        func run(_ id: String, number: Int, daysAgo: Double, product: String = "p") -> CIBuildRun {
            CIBuildRun(
                id: id, productID: product, number: number, createdDate: now.addingTimeInterval(-daysAgo * 86_400), startedDate: nil, finishedDate: nil,
                executionProgress: .complete, completionStatus: .succeeded, startReason: nil, workflowID: "w", workflowName: "Release", sourceBranchOrTag: "main"
            )
        }
        let snapshot = BuildSnapshot(products: [CIProduct(id: "p", name: "Alpha", productType: "APP", appID: "1", appName: nil, bundleID: nil)], runs: [run("r3", number: 3, daysAgo: 1)], workflows: [])
        let older = [run("r3", number: 3, daysAgo: 1), run("r2", number: 2, daysAgo: 40), run("r1", number: 1, daysAgo: 60, product: "other")]

        let all = BuildListModel(snapshot: snapshot, olderRuns: older, scope: .allBuilds, now: now)
        let product = BuildListModel(snapshot: snapshot, olderRuns: older, scope: .product("p"), now: now)
        let workflow = BuildListModel(snapshot: snapshot, olderRuns: older, scope: .workflow("w"), now: now)

        #expect(all.rows.map(\.id) == ["r3", "r2", "r1"])
        #expect(product.rows.map(\.id) == ["r3", "r2"])
        #expect(workflow.rows.map(\.id) == ["r3", "r2", "r1"])
    }

    @Test func withoutProNothingIsAskedOfAppleAndWithItThePageIsRead() async throws {
        final class Lock { var isOpen = false }
        let lock = Lock()
        let transport = MockTransport { _ in MockTransport.Reply(body: (try? Fixture.data("ciBuildRuns-page2")) ?? Data()) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let store = OlderBuildsStore(client: { client }, budget: { nil }, allowed: { lock.isOpen })

        await store.loadOlder(productID: "product-1", known: [])
        #expect(await transport.requests.isEmpty)
        #expect(store.runs(forProductID: "product-1").isEmpty && store.lastError == nil)

        lock.isOpen = true
        await store.loadOlder(productID: "product-1", known: [])
        #expect(await transport.requests.count == 1)
        #expect(!store.runs(forProductID: "product-1").isEmpty)
    }
}
