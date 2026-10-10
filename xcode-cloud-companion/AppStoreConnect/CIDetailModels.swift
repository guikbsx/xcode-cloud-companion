import Foundation

/// How many problems a build or an action reported, as Apple counts them.
nonisolated struct CIIssueCounts: Codable, Sendable, Equatable {
    var analyzerWarnings: Int?
    var errors: Int?
    var testFailures: Int?
    var warnings: Int?

    var total: Int {
        (analyzerWarnings ?? 0) + (errors ?? 0) + (testFailures ?? 0) + (warnings ?? 0)
    }
}

/// The commit a build ran on; Apple fills it for pull request builds, and (to be measured) others.
nonisolated struct CISourceCommit: Codable, Sendable, Equatable {
    var commitSha: String?
    var message: String?
    var authorName: String?
    var webURL: URL?

    /// First eight characters, as Git shows them.
    var shortSha: String? { commitSha.map { String($0.prefix(8)) } }
}

/// Branch or tag patterns of a start condition.
nonisolated struct CIPatterns: Codable, Sendable, Equatable {
    var isAllMatch: Bool
    var patterns: [String]
}

nonisolated enum CIFilesRuleMode: String, Codable, Sendable, Equatable {
    case startIfAnyFileMatches = "START_IF_ANY_FILE_MATCHES"
    case doNotStartIfAllFilesMatch = "DO_NOT_START_IF_ALL_FILES_MATCH"
}

nonisolated enum CIScheduleFrequency: String, Codable, Sendable, Equatable {
    case weekly = "WEEKLY"
    case daily = "DAILY"
    case hourly = "HOURLY"
}

/// What starts a workflow, folded from Apple's seven conditions; nil means the condition is absent.
nonisolated struct CIStartConditions: Codable, Sendable, Equatable {
    var branches: CIPatterns?
    var tags: CIPatterns?
    var pullRequests: CIPatterns?
    var scheduleFrequency: CIScheduleFrequency?
    var filesRule: CIFilesRuleMode?
    var autoCancel: Bool?
    var manualBranches: CIPatterns?
    var manualTags: CIPatterns?
    var manualPullRequests: CIPatterns?

    var allowsManualStart: Bool {
        manualBranches != nil || manualTags != nil || manualPullRequests != nil
    }
}

nonisolated enum CIPlatform: String, Codable, Sendable, Equatable {
    case macOS = "MACOS"
    case iOS = "IOS"
    case tvOS = "TVOS"
    case watchOS = "WATCHOS"
    case visionOS = "VISIONOS"
}

/// One action configured in a workflow.
nonisolated struct CIWorkflowAction: Codable, Sendable, Equatable {
    var name: String?
    var actionType: CIActionType?
    var destination: String?
    var buildDistributionAudience: String?
    var scheme: String?
    var platform: CIPlatform?
    var isRequiredToPass: Bool?
}

nonisolated enum CIIssueType: Codable, Sendable, Equatable {
    case analyzerWarning
    case error
    case testFailure
    case warning
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue {
        case "ANALYZER_WARNING": self = .analyzerWarning
        case "ERROR": self = .error
        case "TEST_FAILURE": self = .testFailure
        case "WARNING": self = .warning
        default: self = .unknown(rawValue ?? "")
        }
    }

    var rawValue: String {
        switch self {
        case .analyzerWarning: "ANALYZER_WARNING"
        case .error: "ERROR"
        case .testFailure: "TEST_FAILURE"
        case .warning: "WARNING"
        case .unknown(let raw): raw
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct CIFileLocation: Codable, Sendable, Equatable {
    var path: String?
    var lineNumber: Int?
}

nonisolated struct CIIssue: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let buildActionID: String
    let type: CIIssueType
    let message: String?
    let category: String?
    let file: CIFileLocation?
}

nonisolated enum CITestStatus: Codable, Sendable, Equatable {
    case success
    case failure
    case mixed
    case skipped
    case expectedFailure
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue {
        case "SUCCESS": self = .success
        case "FAILURE": self = .failure
        case "MIXED": self = .mixed
        case "SKIPPED": self = .skipped
        case "EXPECTED_FAILURE": self = .expectedFailure
        default: self = .unknown(rawValue ?? "")
        }
    }

    var rawValue: String {
        switch self {
        case .success: "SUCCESS"
        case .failure: "FAILURE"
        case .mixed: "MIXED"
        case .skipped: "SKIPPED"
        case .expectedFailure: "EXPECTED_FAILURE"
        case .unknown(let raw): raw
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isFailure: Bool {
        self == .failure || self == .mixed
    }
}

nonisolated struct CITestDeviceResult: Codable, Sendable, Equatable {
    let deviceName: String
    let osVersion: String
    let status: CITestStatus
    let duration: Double?
}

nonisolated struct CITestResult: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let buildActionID: String
    let className: String?
    let name: String?
    let status: CITestStatus
    let message: String?
    let file: CIFileLocation?
    let devices: [CITestDeviceResult]

    var duration: Double? {
        let durations = devices.compactMap(\.duration)
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }
}

nonisolated struct CIArtifact: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let buildActionID: String
    let fileType: String?
    let fileName: String?
    let fileSize: Int?
    /// Short-lived and signed: asked again right before a download, and left out of anything written to disk.
    let downloadURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, buildActionID, fileType, fileName, fileSize
    }

    init(id: String, buildActionID: String, fileType: String?, fileName: String?, fileSize: Int?, downloadURL: URL?) {
        self.id = id
        self.buildActionID = buildActionID
        self.fileType = fileType
        self.fileName = fileName
        self.fileSize = fileSize
        self.downloadURL = downloadURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        buildActionID = try container.decode(String.self, forKey: .buildActionID)
        fileType = try container.decodeIfPresent(String.self, forKey: .fileType)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
        downloadURL = nil
    }
}

/// The TestFlight build a build run produced.
nonisolated struct CIBetaBuild: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let version: String?
    let uploadedDate: Date?
    let processingState: String?
}

// MARK: - JSON:API attributes

nonisolated struct CIGitUserAttributes: Decodable, Sendable {
    let displayName: String?
}

nonisolated struct CISourceCommitAttributes: Decodable, Sendable {
    let commitSha: String?
    let message: String?
    let author: CIGitUserAttributes?
    let webUrl: URL?
}

nonisolated struct CIPatternsAttributes: Decodable, Sendable {
    let isAllMatch: Bool?
    let patterns: [Pattern]?

    struct Pattern: Decodable, Sendable {
        let pattern: String?
    }

    var model: CIPatterns {
        CIPatterns(isAllMatch: isAllMatch ?? false, patterns: (patterns ?? []).compactMap(\.pattern))
    }
}

nonisolated struct CIFilesRuleAttributes: Decodable, Sendable {
    let mode: String?
}

nonisolated struct CIStartConditionAttributes: Decodable, Sendable {
    let source: CIPatternsAttributes?
    let filesAndFoldersRule: CIFilesRuleAttributes?
    let autoCancel: Bool?
    let schedule: Schedule?

    struct Schedule: Decodable, Sendable {
        let frequency: String?
    }
}

nonisolated struct CIIssueAttributes: Decodable, Sendable {
    let issueType: String?
    let message: String?
    let category: String?
    let fileSource: CIFileLocation?
}

nonisolated struct CITestResultDetailAttributes: Decodable, Sendable {
    let className: String?
    let name: String?
    let status: String?
    let message: String?
    let fileSource: CIFileLocation?
    let destinationTestResults: [CITestResultAttributes.DestinationTestResult]?
}

nonisolated struct CIArtifactAttributes: Decodable, Sendable {
    let fileType: String?
    let fileName: String?
    let fileSize: Int?
    let downloadUrl: URL?
}

nonisolated struct CIBetaBuildAttributes: Decodable, Sendable {
    let version: String?
    let uploadedDate: Date?
    let processingState: String?
}

// MARK: - Mapping

nonisolated extension JSONAPIDocument where Attributes == CIIssueAttributes {
    func issues(buildActionID: String) -> [CIIssue] {
        data.map { resource in
            CIIssue(
                id: resource.id, buildActionID: buildActionID, type: CIIssueType(rawValue: resource.attributes?.issueType),
                message: resource.attributes?.message, category: resource.attributes?.category, file: resource.attributes?.fileSource
            )
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CITestResultDetailAttributes {
    func testResults(buildActionID: String) -> [CITestResult] {
        data.map { resource in
            let attributes = resource.attributes
            return CITestResult(
                id: resource.id, buildActionID: buildActionID, className: attributes?.className, name: attributes?.name,
                status: CITestStatus(rawValue: attributes?.status), message: attributes?.message, file: attributes?.fileSource,
                devices: (attributes?.destinationTestResults ?? []).map {
                    CITestDeviceResult(
                        deviceName: $0.deviceName ?? "?", osVersion: $0.osVersion ?? "?",
                        status: CITestStatus(rawValue: $0.status), duration: $0.duration
                    )
                }
            )
        }
    }
}

nonisolated extension JSONAPIResource where Attributes == CIArtifactAttributes {
    func artifact(buildActionID: String) -> CIArtifact {
        CIArtifact(
            id: id, buildActionID: buildActionID, fileType: attributes?.fileType, fileName: attributes?.fileName,
            fileSize: attributes?.fileSize, downloadURL: attributes?.downloadUrl
        )
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIArtifactAttributes {
    func artifacts(buildActionID: String) -> [CIArtifact] {
        data.map { $0.artifact(buildActionID: buildActionID) }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIBetaBuildAttributes {
    var betaBuilds: [CIBetaBuild] {
        data.map {
            CIBetaBuild(
                id: $0.id, version: $0.attributes?.version, uploadedDate: $0.attributes?.uploadedDate,
                processingState: $0.attributes?.processingState
            )
        }
    }
}
