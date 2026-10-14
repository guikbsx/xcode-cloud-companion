import Foundation

/// `processingState` of a build. Only `VALID` was seen on a real account (13/10/2026); the others are Apple's documented values.
nonisolated enum TestFlightProcessing: String, Codable, Sendable {
    case processing, failed, invalid, valid, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    init(apple value: String?) {
        switch value {
        case "PROCESSING": self = .processing
        case "FAILED": self = .failed
        case "INVALID": self = .invalid
        case "VALID": self = .valid
        default: self = .unknown
        }
    }
}

/// `internalBuildState` and `externalBuildState` of a build. Seen on a real account: `READY_FOR_BETA_SUBMISSION`,
/// `READY_FOR_BETA_TESTING`, `IN_BETA_TESTING`, `EXPIRED`. The review, processing and rejection values are Apple's
/// documented names, not yet seen; any other (a missing export compliance, say) reads as `unknown`.
nonisolated enum TestFlightBetaState: String, Codable, Sendable {
    case processing, readyForSubmission, waitingForReview, inReview, rejected, approved, ready, testing, expired, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    init(apple value: String?) {
        switch value {
        case "PROCESSING": self = .processing
        case "READY_FOR_BETA_SUBMISSION": self = .readyForSubmission
        case "WAITING_FOR_BETA_REVIEW": self = .waitingForReview
        case "IN_BETA_REVIEW": self = .inReview
        case "BETA_REJECTED": self = .rejected
        case "BETA_APPROVED": self = .approved
        case "READY_FOR_BETA_TESTING": self = .ready
        case "IN_BETA_TESTING": self = .testing
        case "EXPIRED": self = .expired
        default: self = .unknown
        }
    }
}

/// `betaReviewState` of the submission of a build to the beta review. Only `APPROVED` was seen on a real account.
nonisolated enum TestFlightReviewState: String, Codable, Sendable {
    case waiting, inReview, rejected, approved, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    init(apple value: String?) {
        switch value {
        case "WAITING_FOR_REVIEW": self = .waiting
        case "IN_REVIEW": self = .inReview
        case "REJECTED": self = .rejected
        case "APPROVED": self = .approved
        default: self = .unknown
        }
    }
}

nonisolated struct TestFlightGroup: Codable, Sendable, Equatable {
    var name: String
    var isInternal: Bool
}

/// Where a TestFlight build stands, in the one word the card says.
nonisolated enum TestFlightStatus: Sendable, Equatable {
    case processing
    case processingFailed
    case waitingForReview
    case inReview
    case rejected
    /// In testing with at least one group of testers.
    case available
    /// Processed, but in no group yet.
    case ready
    case expired
    case unknown
}

/// A build of an app as TestFlight lists it. Apple dates the upload, the expiry and the sending to the beta review;
/// the end of the processing and the approval are states without a date.
nonisolated struct TestFlightBuild: Codable, Sendable, Equatable, Identifiable {
    var id: String
    /// The build number (`version` of the build in Apple's words).
    var buildNumber: String?
    /// “1.4”: the version of the app the build belongs to.
    var marketingVersion: String?
    var platform: String?
    var uploadedDate: Date?
    var expirationDate: Date?
    var isMarkedExpired: Bool
    var processing: TestFlightProcessing
    var internalState: TestFlightBetaState
    var externalState: TestFlightBetaState
    /// Nil when the build was never sent to the beta review.
    var review: TestFlightReviewState?
    var reviewSubmittedDate: Date?
    var groups: [TestFlightGroup]

    /// “1.4 (412)”, or the number alone when the version is not known.
    var label: String {
        switch (marketingVersion?.nilIfBlank, buildNumber?.nilIfBlank) {
        case let (version?, number?): "\(version) (\(number))"
        case let (version?, nil): version
        case let (nil, number?): number
        case (nil, nil): "?"
        }
    }

    func isExpired(at now: Date) -> Bool {
        isMarkedExpired || (internalState == .expired && externalState == .expired) || (expirationDate.map { $0 <= now } ?? false)
    }

    func status(at now: Date) -> TestFlightStatus {
        if isExpired(at: now) { return .expired }
        switch processing {
        case .failed, .invalid: return .processingFailed
        case .processing: return .processing
        case .valid, .unknown: break
        }
        if internalState == .processing || externalState == .processing { return .processing }
        // The beta review speaks first: a build that tests inside while it waits for its review is still waiting for it.
        if externalState != .testing {
            if externalState == .rejected || review == .rejected { return .rejected }
            if externalState == .inReview || review == .inReview { return .inReview }
            if externalState == .waitingForReview || review == .waiting { return .waitingForReview }
        }
        if internalState == .testing || externalState == .testing { return .available }
        if internalState == .ready || externalState == .ready || externalState == .readyForSubmission || externalState == .approved { return .ready }
        return .unknown
    }

    /// In testing with an external group, which is what the banner of availability says.
    func isAvailableToExternalTesters(at now: Date) -> Bool {
        externalState == .testing && !isExpired(at: now)
    }

    /// The testers the build is for, from its groups and from the states: Apple does not always list the group of
    /// internal testers who get every build.
    func testers(at now: Date) -> TestFlightTesters {
        let live = !isExpired(at: now)
        let hasExternalGroup = groups.contains { !$0.isInternal }
        let hasInternalGroup = groups.contains { $0.isInternal }
        let externalInvolved = [.testing, .waitingForReview, .inReview, .rejected, .approved].contains(externalState) || review != nil
        return TestFlightTesters(
            hasInternal: hasInternalGroup || (live && internalState == .testing),
            hasExternal: hasExternalGroup || externalInvolved
        )
    }

    /// The days left before the build stops working: nil once expired or when Apple gave no date.
    func daysLeft(at now: Date) -> Int? {
        guard !isExpired(at: now), let expirationDate else { return nil }
        return max(1, Int((expirationDate.timeIntervalSince(now) / 86400).rounded(.up)))
    }
}

nonisolated struct TestFlightTesters: Sendable, Equatable {
    var hasInternal: Bool
    var hasExternal: Bool

    var isEmpty: Bool { !hasInternal && !hasExternal }
}

/// An app that hands builds to TestFlight, as a sync knows it.
nonisolated struct TestFlightApp: Sendable, Equatable, Identifiable {
    /// The Xcode Cloud product: what a muted app and a palette are keyed by.
    var productID: String
    var appID: String
    var name: String
    /// When the newest successful build of a workflow that ships to TestFlight finished.
    var newestShippedFinish: Date?

    var id: String { productID }

    /// The apps with a workflow that hands its archive to TestFlight and an App Store Connect app to ask about.
    static func shipping(in snapshot: BuildSnapshot) -> [TestFlightApp] {
        snapshot.products.compactMap { product in
            guard let appID = product.appID else { return nil }
            let shipping = Set(snapshot.workflows.filter { $0.productID == product.id && $0.shipsToTestFlight }.map(\.id))
            guard !shipping.isEmpty else { return nil }
            let finish = snapshot.runs
                .filter { $0.productID == product.id && $0.completionStatus == .succeeded && $0.workflowID.map(shipping.contains) == true }
                .compactMap { $0.finishedDate }
                .max()
            return TestFlightApp(productID: product.id, appID: appID, name: product.displayName, newestShippedFinish: finish)
        }
    }
}

// MARK: - Reading

/// The times at which Cumulus itself saw a build move on. Apple dates none of these, so they are not Apple's times:
/// they are the time of the read that first showed the new state, and only when the read before showed the old one.
nonisolated struct TestFlightObservation: Codable, Sendable, Equatable {
    var processedSeenAt: Date?
    var internalAvailableSeenAt: Date?
    var externalAvailableSeenAt: Date?
}

/// What the last read of an app said, kept on disk with the times Cumulus saw things change.
nonisolated struct TestFlightReading: Codable, Sendable, Equatable {
    var appID: String
    /// Newest first.
    var builds: [TestFlightBuild]
    var readAt: Date
    var observations: [String: TestFlightObservation] = [:]

    /// The reading that follows `previous`: what changed between the two reads is dated by this one.
    static func following(_ previous: TestFlightReading?, appID: String, builds: [TestFlightBuild], at now: Date) -> TestFlightReading {
        var observations: [String: TestFlightObservation] = [:]
        for build in builds {
            var seen = previous?.observations[build.id] ?? TestFlightObservation()
            if let before = previous?.builds.first(where: { $0.id == build.id }) {
                if seen.processedSeenAt == nil, before.processing == .processing, build.processing == .valid {
                    seen.processedSeenAt = now
                }
                if seen.internalAvailableSeenAt == nil, before.internalState != .testing, build.internalState == .testing {
                    seen.internalAvailableSeenAt = now
                }
                if seen.externalAvailableSeenAt == nil, before.externalState != .testing, build.externalState == .testing {
                    seen.externalAvailableSeenAt = now
                }
            }
            if seen != TestFlightObservation() { observations[build.id] = seen }
        }
        return TestFlightReading(appID: appID, builds: builds, readAt: now, observations: observations)
    }

    func build(id: String) -> TestFlightBuild? {
        builds.first { $0.id == id }
    }
}

// MARK: - Decoding

nonisolated struct TestFlightBuildAttributes: Decodable, Sendable {
    let version: String?
    let uploadedDate: Date?
    let expirationDate: Date?
    let expired: Bool?
    let processingState: String?
}

nonisolated extension JSONAPIDocument where Attributes == TestFlightBuildAttributes {
    /// The builds with their states, review, version and groups, newest upload first. Whatever Apple left out reads as unknown.
    var testFlightBuilds: [TestFlightBuild] {
        let builds = data.map { resource -> TestFlightBuild in
            let detail = includedResource(for: resource.relationship("buildBetaDetail"))?.attributes
            let review = includedResource(for: resource.relationship("betaAppReviewSubmission"))?.attributes
            let version = includedResource(for: resource.relationship("preReleaseVersion"))?.attributes
            let groups = resource.relationships("betaGroups").compactMap { includedResource(for: $0)?.attributes }.compactMap { group -> TestFlightGroup? in
                guard let name = group.name else { return nil }
                return TestFlightGroup(name: name, isInternal: group.isInternalGroup ?? false)
            }
            return TestFlightBuild(
                id: resource.id, buildNumber: resource.attributes?.version, marketingVersion: version?.version, platform: version?.platform,
                uploadedDate: resource.attributes?.uploadedDate, expirationDate: resource.attributes?.expirationDate,
                isMarkedExpired: resource.attributes?.expired ?? false, processing: TestFlightProcessing(apple: resource.attributes?.processingState),
                internalState: TestFlightBetaState(apple: detail?.internalBuildState), externalState: TestFlightBetaState(apple: detail?.externalBuildState),
                review: review.map { TestFlightReviewState(apple: $0.betaReviewState) }, reviewSubmittedDate: review?.submittedDate, groups: groups
            )
        }
        return builds.sorted { ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast) }
    }
}
