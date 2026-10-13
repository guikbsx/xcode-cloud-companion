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
    let now: @Sendable () -> Date
    private var token: AppStoreConnectToken?
    private var lastRateLimit: RateLimit?

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

    /// Workflows with their configuration: start conditions, actions, Xcode and macOS versions, repository.
    func workflowDetails(productID: String, maxPages: Int = 2) async throws(AppStoreConnectError) -> [CIWorkflow] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.workflowDetails(productID: productID),
            of: CIWorkflowAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap(\.workflows)
    }

    func issues(buildActionID: String, maxPages: Int = 5) async throws(AppStoreConnectError) -> [CIIssue] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.issues(buildActionID: buildActionID),
            of: CIIssueAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap { $0.issues(buildActionID: buildActionID) }
    }

    /// Every test case of an action with its message and per-device results.
    func testResults(buildActionID: String, maxPages: Int = 15) async throws(AppStoreConnectError) -> [CITestResult] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.testResultDetails(buildActionID: buildActionID),
            of: CITestResultDetailAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap { $0.testResults(buildActionID: buildActionID) }
    }

    func artifacts(buildActionID: String, maxPages: Int = 2) async throws(AppStoreConnectError) -> [CIArtifact] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.artifacts(buildActionID: buildActionID),
            of: CIArtifactAttributes.self,
            maxPages: maxPages
        )
        return pages.flatMap { $0.artifacts(buildActionID: buildActionID) }
    }

    /// The artifact with a fresh download address: the address is short-lived, so it is asked for just before use.
    func artifact(id: String, buildActionID: String) async throws(AppStoreConnectError) -> CIArtifact {
        let single: JSONAPISingleDocument<CIArtifactAttributes> = try await decoded(at: AppStoreConnectEndpoint.artifact(id: id))
        return single.data.artifact(buildActionID: buildActionID)
    }

    func betaBuilds(buildRunID: String) async throws(AppStoreConnectError) -> [CIBetaBuild] {
        let pages = try await collectPages(
            from: AppStoreConnectEndpoint.betaBuilds(buildRunID: buildRunID),
            of: CIBetaBuildAttributes.self,
            maxPages: 1
        )
        return pages.flatMap(\.betaBuilds)
    }

    /// App icons by app ID, in one request: every app with whichever build Apple includes, or the newest builds of the account.
    func xcodeVersions() async throws(AppStoreConnectError) -> [CIXcodeVersion] {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.xcodeVersions, of: CIXcodeVersionAttributes.self, maxPages: 2)
        return pages.flatMap(\.xcodeVersions)
    }

    func appIcons(fromNewestBuilds: Bool) async throws(AppStoreConnectError) -> [String: CIAppIcon] {
        if fromNewestBuilds {
            let page: JSONAPIDocument<CIBuildIconAttributes> = try await document(at: AppStoreConnectEndpoint.latestBuildIcons)
            return page.appIcons
        }
        let page: JSONAPIDocument<CIAppIconsAttributes> = try await document(at: AppStoreConnectEndpoint.appIcons)
        return page.appIcons
    }

    /// What Apple's last response said about the hourly budget of this key (nil before any response).
    func rateLimit() -> RateLimit? {
        lastRateLimit
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

    func collectPages<Attributes: Decodable & Sendable>(
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

    func document<Attributes: Decodable & Sendable>(at url: URL) async throws(AppStoreConnectError) -> JSONAPIDocument<Attributes> {
        try await decoded(at: url)
    }

    func decoded<Body: Decodable & Sendable>(at url: URL) async throws(AppStoreConnectError) -> Body {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    /// Sends one request and decodes the answer. It never sends twice: a POST is not safe to repeat.
    func send<Body: Decodable & Sendable>(_ prepared: URLRequest) async throws(AppStoreConnectError) -> Body {
        let data = try await accepted(prepared)
        do {
            return try JSONDecoder.appStoreConnect.decode(Body.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    /// Sends one request, once, and gives the body of a 2xx answer as it came: Apple said yes, whatever the body holds.
    func accepted(_ prepared: URLRequest) async throws(AppStoreConnectError) -> Data {
        var request = prepared
        request.setValue("Bearer \(try currentToken())", forHTTPHeaderField: "Authorization")

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
        if let rateLimit = RateLimit(header: httpResponse.value(forHTTPHeaderField: "X-Rate-Limit")) {
            lastRateLimit = rateLimit
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw .unauthorized(status: 401)
        case 429:
            throw .rateLimited
        default:
            let entry = (try? JSONDecoder().decode(JSONAPIErrorResponse.self, from: data))?.errors.first
            switch httpResponse.statusCode {
            case 403:
                throw .forbidden(code: entry?.code, detail: entry?.detail)
            case 409, 422:
                throw .rejected(
                    status: httpResponse.statusCode, code: entry?.code, title: entry?.title,
                    detail: entry?.detail, pointer: entry?.source?.pointer
                )
            default:
                throw .server(status: httpResponse.statusCode, detail: entry?.detail)
            }
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
