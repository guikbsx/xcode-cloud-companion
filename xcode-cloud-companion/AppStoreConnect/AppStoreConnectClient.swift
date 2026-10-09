import Foundation

nonisolated protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

actor AppStoreConnectClient {
    private let credentials: AppStoreConnectCredentials
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var token: AppStoreConnectToken?

    init(
        credentials: AppStoreConnectCredentials,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    func products(pageSize: Int = AppStoreConnectEndpoint.maximumPageSize, maxPages: Int = 5) async throws(AppStoreConnectError) -> [CIProduct] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.products(pageSize: pageSize),
            of: CIProductAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap(\.products)
    }

    /// Build runs come newest first; paging stops at the first page that reaches `createdSince`.
    func buildRuns(
        productID: String,
        createdSince: Date? = nil,
        pageSize: Int = 50,
        maxPages: Int = 10
    ) async throws(AppStoreConnectError) -> [CIBuildRun] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.buildRuns(productID: productID, pageSize: pageSize),
            of: CIBuildRunAttributes.self,
            maxPages: maxPages
        ) { page in
            guard let createdSince else { return true }
            return page.buildRuns(productID: productID).allSatisfy { run in
                run.createdDate.map { $0 >= createdSince } ?? true
            }
        }
        let runs = pages.flatMap { $0.buildRuns(productID: productID) }
        guard let createdSince else { return runs }
        return runs.filter { run in run.createdDate.map { $0 >= createdSince } ?? true }
    }

    func buildActions(buildRunID: String, maxPages: Int = 2) async throws(AppStoreConnectError) -> [CIBuildAction] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.buildActions(buildRunID: buildRunID),
            of: CIBuildActionAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap { $0.buildActions(buildRunID: buildRunID) }
    }

    func workflows(productID: String, maxPages: Int = 2) async throws(AppStoreConnectError) -> [CIWorkflow] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.workflows(productID: productID),
            of: CIWorkflowAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap(\.workflows)
    }

    /// One entry per simulated device, sorted by name; `maxPages` × 200 test cases at most.
    func testDeviceRuns(buildActionID: String, maxPages: Int = 15) async throws(AppStoreConnectError) -> [CITestDeviceRun] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.testResults(buildActionID: buildActionID),
            of: CITestResultAttributes.self,
            maxPages: maxPages
        )
        var runs: [String: CITestDeviceRun] = [:]
        for page in pages {
            page.accumulateDeviceRuns(into: &runs)
        }
        return runs.keys.sorted().compactMap { runs[$0] }
    }

    // MARK: - Paging

    private func collectPages<Attributes: Decodable & Sendable>(
        from firstURL: URL,
        of _: Attributes.Type,
        maxPages: Int,
        continueAfter shouldContinue: (JSONAPIDocument<Attributes>) -> Bool = { _ in true }
    ) async throws(AppStoreConnectError) -> [JSONAPIDocument<Attributes>] {
        var pages: [JSONAPIDocument<Attributes>] = []
        var nextURL: URL? = firstURL
        while let url = nextURL, pages.count < max(maxPages, 1) {
            let page: JSONAPIDocument<Attributes> = try await document(at: url)
            pages.append(page)
            guard shouldContinue(page), let next = page.links?.next else { break }
            // The bearer token must never leave Apple's API host.
            guard AppStoreConnectEndpoint.isTrusted(next) else { throw .invalidResponse }
            nextURL = next
        }
        return pages
    }

    // MARK: - Transport

    private func document<Attributes: Decodable & Sendable>(at url: URL) async throws(AppStoreConnectError) -> JSONAPIDocument<Attributes> {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            throw .network(error.code)
        } catch is CancellationError {
            throw .network(.cancelled)
        } catch {
            throw .network(.unknown)
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw .invalidResponse }
        switch httpResponse.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<Attributes>.self, from: data)
            } catch {
                throw .decoding(String(describing: error))
            }
        case 401, 403:
            throw .unauthorized(status: httpResponse.statusCode)
        case 429:
            throw .rateLimited
        default:
            let detail = (try? JSONDecoder().decode(JSONAPIErrorResponse.self, from: data))?.errors.first?.detail
            throw .server(status: httpResponse.statusCode, detail: detail)
        }
    }

    private func currentToken() throws(AppStoreConnectError) -> String {
        let date = now()
        if let token, token.isUsable(at: date) {
            return token.value
        }
        do {
            let newToken = try AppStoreConnectToken(credentials: credentials, issuedAt: date)
            token = newToken
            return newToken.value
        } catch {
            throw .invalidPrivateKey
        }
    }
}
