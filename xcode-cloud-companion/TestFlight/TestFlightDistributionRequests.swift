import Foundation

/// The identifiers and locales that go into a path or a body are letters, digits and hyphens only.
private nonisolated func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

/// The groups a build is given to (`POST`) or taken from (`DELETE`): the same body for both, several groups in one request.
nonisolated struct BetaGroupMembershipRequest: Equatable, Sendable {
    let buildID: String
    let groupIDs: [String]

    var isWellFormed: Bool {
        isSafeIdentifier(buildID) && !groupIDs.isEmpty && Set(groupIDs).count == groupIDs.count && groupIDs.allSatisfy(isSafeIdentifier)
    }

    func body() throws -> Data {
        let data = groupIDs.map { ["type": "betaGroups", "id": $0] }
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// What a build says to its testers, in one language: `POST` for a language that has no notes yet, `PATCH` for one that has.
nonisolated struct BetaNoteRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case create(locale: String)
        case update(localizationID: String)
    }

    /// Apple's limit for the “What to test” text.
    static let maximumLength = 4000

    let buildID: String
    let kind: Kind
    let text: String

    var isWellFormed: Bool {
        guard isSafeIdentifier(buildID), text.count <= Self.maximumLength else { return false }
        switch kind {
        case .create(let locale): return isSafeIdentifier(locale)
        case .update(let id): return isSafeIdentifier(id)
        }
    }

    func body() throws -> Data {
        let data: [String: Any]
        switch kind {
        case .create(let locale):
            data = [
                "type": "betaBuildLocalizations",
                "attributes": ["locale": locale, "whatsNew": text],
                "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
            ]
        case .update(let id):
            data = ["type": "betaBuildLocalizations", "id": id, "attributes": ["whatsNew": text]]
        }
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// Whether Apple tells the testers by itself when the build reaches them: the one switch the toggle “Notify testers” moves.
nonisolated struct BuildAutoNotifyRequest: Equatable, Sendable {
    let detailID: String
    let isEnabled: Bool

    var isWellFormed: Bool { isSafeIdentifier(detailID) }

    func body() throws -> Data {
        let data: [String: Any] = ["type": "buildBetaDetails", "id": detailID, "attributes": ["autoNotifyEnabled": isEnabled]]
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// The build sent to Apple's beta review, which an external group needs before its testers get the build.
nonisolated struct BetaReviewSubmissionRequest: Equatable, Sendable {
    let buildID: String

    var isWellFormed: Bool { isSafeIdentifier(buildID) }

    func body() throws -> Data {
        let data: [String: Any] = [
            "type": "betaAppReviewSubmissions",
            "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
        ]
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// A build made unavailable for testing. Apple has no way back, so `expired: false` is never built.
nonisolated struct BuildExpirationRequest: Equatable, Sendable {
    let buildID: String

    var isWellFormed: Bool { isSafeIdentifier(buildID) }

    func body() throws -> Data {
        let data: [String: Any] = ["type": "builds", "id": buildID, "attributes": ["expired": true]]
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// The test notes of a build in one language, as Apple holds them.
nonisolated struct BetaBuildNote: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var locale: String
    var text: String
}

nonisolated struct BetaBuildLocalizationAttributes: Decodable, Sendable {
    let locale: String?
    let whatsNew: String?
}

nonisolated extension JSONAPIDocument where Attributes == BetaBuildLocalizationAttributes {
    var notes: [BetaBuildNote] {
        data.compactMap { resource in
            guard let locale = resource.attributes?.locale else { return nil }
            return BetaBuildNote(id: resource.id, locale: locale, text: resource.attributes?.whatsNew ?? "")
        }
    }
}

extension AppStoreConnectClient {
    /// One build as `testFlightBuilds` reads it: what a distribution did, as Apple has it now.
    func testFlightBuild(id: String) async throws(AppStoreConnectError) -> TestFlightBuild? {
        guard isSafeIdentifier(id) else { throw .invalidResponse }
        let document: JSONAPISingleDocument<TestFlightBuildAttributes> = try await decoded(at: AppStoreConnectEndpoint.testFlightBuild(id: id))
        return JSONAPIDocument(single: document).testFlightBuilds.first
    }

    func betaBuildNotes(buildID: String) async throws(AppStoreConnectError) -> [BetaBuildNote] {
        guard isSafeIdentifier(buildID) else { throw .invalidResponse }
        let pages = try await collectPages(from: AppStoreConnectEndpoint.betaBuildLocalizations(buildID: buildID), of: BetaBuildLocalizationAttributes.self, maxPages: 1)
        return pages.flatMap(\.notes)
    }

    /// Gives a build to groups. One request, never repeated.
    func addBetaGroups(_ request: BetaGroupMembershipRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        try await write("POST", AppStoreConnectEndpoint.buildBetaGroups(buildID: request.buildID), body: body)
    }

    /// Takes a build from groups. One request, never repeated.
    func removeBetaGroups(_ request: BetaGroupMembershipRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        try await write("DELETE", AppStoreConnectEndpoint.buildBetaGroups(buildID: request.buildID), body: body)
    }

    /// Writes the test notes of one language. One request, never repeated.
    func writeBetaNote(_ request: BetaNoteRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        switch request.kind {
        case .create:
            try await write("POST", AppStoreConnectEndpoint.createBetaBuildLocalization, body: body)
        case .update(let id):
            try await write("PATCH", AppStoreConnectEndpoint.betaBuildLocalization(id: id), body: body)
        }
    }

    /// Switches whether Apple tells the testers by itself. One request, never repeated.
    func setAutoNotify(_ request: BuildAutoNotifyRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        try await write("PATCH", AppStoreConnectEndpoint.buildBetaDetail(id: request.detailID), body: body)
    }

    /// Sends the build to the beta review. One request, never repeated.
    func submitForBetaReview(_ request: BetaReviewSubmissionRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        try await write("POST", AppStoreConnectEndpoint.createBetaAppReviewSubmission, body: body)
    }

    /// Expires a build. One request, never repeated.
    func expireBuild(_ request: BuildExpirationRequest) async throws(AppStoreConnectError) {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        try await write("PATCH", AppStoreConnectEndpoint.updateBuild(id: request.buildID), body: body)
    }

    /// A 2xx is Apple saying yes, whatever the body holds (a `204` has none): nothing is decoded.
    private func write(_ method: String, _ url: URL, body: Data) async throws(AppStoreConnectError) {
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        _ = try await accepted(urlRequest)
    }
}
