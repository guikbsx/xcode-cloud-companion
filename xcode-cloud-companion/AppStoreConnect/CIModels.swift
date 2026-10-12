import Foundation

nonisolated struct CIProduct: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let productType: String?
    let appID: String?
    let appName: String?
    let bundleID: String?
}

nonisolated extension CIProduct {
    /// What the interface calls the app: its App Store name when it has one. `name` stays the key of an app's colour and of its usage.
    var displayName: String {
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return appName
    }

    /// Where room is counted (the menu's app column, a build row), a name gives way after this many characters.
    static let compactNameLength = 14

    static func compact(_ name: String) -> String {
        name.count > compactNameLength ? name.prefix(compactNameLength - 1) + "…" : name
    }
}

/// Where Apple serves an app's icon, from a build's `iconAssetToken`: a template whose size and format are filled in.
nonisolated struct CIAppIcon: Codable, Sendable, Equatable {
    var templateURL: String

    /// A Mac icon comes with its own shape and margins; every other one is a full square, to be rounded like on the Home Screen.
    var isMacIcon: Bool {
        templateURL.contains(".icns/")
    }

    /// The image at `pixels` × `pixels`, only ever from Apple's image servers; no credential goes with the request.
    func imageURL(pixels: Int) -> URL? {
        let address = templateURL
            .replacing("{w}", with: String(pixels))
            .replacing("{h}", with: String(pixels))
            .replacing("{f}", with: "png")
        guard let url = URL(string: address), url.scheme == "https", let host = url.host(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }
        return url
    }
}

nonisolated struct CIBuildRun: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let productID: String
    let number: Int?
    let createdDate: Date?
    let startedDate: Date?
    let finishedDate: Date?
    let executionProgress: CIExecutionProgress
    let completionStatus: CICompletionStatus?
    let startReason: String?
    let workflowID: String?
    let workflowName: String?
    let sourceBranchOrTag: String?
    // Added for the window; absent from caches written before, which decode them as nil.
    var issueCounts: CIIssueCounts? = nil
    var sourceCommit: CISourceCommit? = nil
    var cancelReason: String? = nil
    var isPullRequestBuild: Bool? = nil
    var pullRequestNumber: Int? = nil
    var pullRequestTitle: String? = nil
}

nonisolated struct CIBuildAction: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let buildRunID: String
    let name: String?
    let actionType: CIActionType?
    let startedDate: Date?
    let finishedDate: Date?
    let executionProgress: CIExecutionProgress
    let completionStatus: CICompletionStatus?
    let isRequiredToPass: Bool?
    var issueCounts: CIIssueCounts? = nil
}

/// What one simulated device did during a test action: Apple bills each device for its own time.
nonisolated struct CITestDeviceRun: Codable, Sendable, Equatable {
    let deviceName: String
    let osVersion: String
    var testCount = 0
    var failedCount = 0
    var totalSeconds: Double = 0
}

nonisolated struct CIWorkflow: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    /// Destinations configured on each test action, in the workflow's order.
    let testDestinationCounts: [Int]
    // Added for the window; absent from caches written before.
    var productID: String? = nil
    var description: String? = nil
    var isEnabled: Bool? = nil
    var isLockedForEditing: Bool? = nil
    var clean: Bool? = nil
    var containerFilePath: String? = nil
    var lastModifiedDate: Date? = nil
    var actions: [CIWorkflowAction] = []
    var startConditions: CIStartConditions? = nil
    var xcodeVersionName: String? = nil
    var macOSVersionName: String? = nil
    var repositoryName: String? = nil
    /// The bare Xcode version number (“27.1”), to compare with what Xcode Cloud offers.
    var xcodeVersion: String? = nil
    /// The versions' identifiers, for a change of version.
    var xcodeVersionID: String? = nil
    var macOSVersionID: String? = nil
}

nonisolated struct CIXcodeVersionAttributes: Decodable, Sendable {
    let name: String?
    let version: String?
}

nonisolated extension JSONAPIDocument where Attributes == CIXcodeVersionAttributes {
    var xcodeVersions: [CIXcodeVersion] {
        data.compactMap { resource in
            guard let version = resource.attributes?.version else { return nil }
            return CIXcodeVersion(id: resource.id, name: resource.attributes?.name ?? "Xcode \(version)", version: version)
        }
    }
}

nonisolated enum CIExecutionProgress: Sendable, Equatable {
    case pending
    case running
    case complete
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue {
        case "PENDING": self = .pending
        case "RUNNING": self = .running
        case "COMPLETE": self = .complete
        default: self = .unknown(rawValue ?? "")
        }
    }
}

nonisolated enum CICompletionStatus: Sendable, Equatable {
    case succeeded
    case failed
    case errored
    case canceled
    case skipped
    case unknown(String)

    init?(rawValue: String?) {
        switch rawValue {
        case nil: return nil
        case "SUCCEEDED": self = .succeeded
        case "FAILED": self = .failed
        case "ERRORED": self = .errored
        case "CANCELED": self = .canceled
        case "SKIPPED": self = .skipped
        case let other?: self = .unknown(other)
        }
    }
}

nonisolated enum CIActionType: Sendable, Equatable {
    case build
    case analyze
    case test
    case archive
    case unknown(String)

    init?(rawValue: String?) {
        switch rawValue {
        case nil: return nil
        case "BUILD": self = .build
        case "ANALYZE": self = .analyze
        case "TEST": self = .test
        case "ARCHIVE": self = .archive
        case let other?: self = .unknown(other)
        }
    }
}

// MARK: - Codable through Apple's raw values

nonisolated extension CIExecutionProgress: Codable {
    var rawValue: String {
        switch self {
        case .pending: "PENDING"
        case .running: "RUNNING"
        case .complete: "COMPLETE"
        case .unknown(let value): value
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

nonisolated extension CICompletionStatus: Codable {
    var rawValue: String {
        switch self {
        case .succeeded: "SUCCEEDED"
        case .failed: "FAILED"
        case .errored: "ERRORED"
        case .canceled: "CANCELED"
        case .skipped: "SKIPPED"
        case .unknown(let value): value
        }
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = CICompletionStatus(rawValue: value) ?? .unknown(value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated extension CIActionType: Codable {
    var rawValue: String {
        switch self {
        case .build: "BUILD"
        case .analyze: "ANALYZE"
        case .test: "TEST"
        case .archive: "ARCHIVE"
        case .unknown(let value): value
        }
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = CIActionType(rawValue: value) ?? .unknown(value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - JSON:API attributes

nonisolated struct CIProductAttributes: Decodable, Sendable {
    let name: String?
    let productType: String?
}

nonisolated struct CIBuildRunAttributes: Decodable, Sendable {
    let number: Int?
    let createdDate: Date?
    let startedDate: Date?
    let finishedDate: Date?
    let executionProgress: String?
    let completionStatus: String?
    let startReason: String?
    let cancelReason: String?
    let isPullRequestBuild: Bool?
    let issueCounts: CIIssueCounts?
    let sourceCommit: CISourceCommitAttributes?
}

nonisolated struct CIBuildActionAttributes: Decodable, Sendable {
    let name: String?
    let actionType: String?
    let startedDate: Date?
    let finishedDate: Date?
    let executionProgress: String?
    let completionStatus: String?
    let isRequiredToPass: Bool?
    let issueCounts: CIIssueCounts?
}

nonisolated struct CITestResultAttributes: Decodable, Sendable {
    let status: String?
    let destinationTestResults: [DestinationTestResult]?

    struct DestinationTestResult: Decodable, Sendable {
        let deviceName: String?
        let osVersion: String?
        let status: String?
        let duration: Double?
    }
}

nonisolated struct CIIconAssetToken: Decodable, Sendable {
    let templateUrl: String?
}

/// `GET /v1/apps` asked only for its builds relationship: the icons are in the included builds.
nonisolated struct CIAppIconsAttributes: Decodable, Sendable {}

nonisolated struct CIBuildIconAttributes: Decodable, Sendable {
    let iconAssetToken: CIIconAssetToken?
}

nonisolated struct CIWorkflowAttributes: Decodable, Sendable {
    let name: String?
    let description: String?
    let isEnabled: Bool?
    let isLockedForEditing: Bool?
    let clean: Bool?
    let containerFilePath: String?
    let lastModifiedDate: Date?
    let branchStartCondition: CIStartConditionAttributes?
    let tagStartCondition: CIStartConditionAttributes?
    let pullRequestStartCondition: CIStartConditionAttributes?
    let scheduledStartCondition: CIStartConditionAttributes?
    let manualBranchStartCondition: CIStartConditionAttributes?
    let manualTagStartCondition: CIStartConditionAttributes?
    let manualPullRequestStartCondition: CIStartConditionAttributes?
    let actions: [Action]?

    struct Action: Decodable, Sendable {
        let name: String?
        let actionType: String?
        let destination: String?
        let buildDistributionAudience: String?
        let scheme: String?
        let platform: String?
        let isRequiredToPass: Bool?
        let testConfiguration: TestConfiguration?
    }

    struct TestConfiguration: Decodable, Sendable {
        let testDestinations: [TestDestination]?
    }

    struct TestDestination: Decodable, Sendable {
        let deviceTypeName: String?
        let runtimeName: String?
    }
}

// MARK: - Mapping

nonisolated extension JSONAPIDocument where Attributes == CIProductAttributes {
    var products: [CIProduct] {
        data.map { resource in
            let appIdentifier = resource.relationship("app")
            let app = includedResource(for: appIdentifier)
            return CIProduct(
                id: resource.id,
                name: resource.attributes?.name ?? app?.attributes?.name ?? resource.id,
                productType: resource.attributes?.productType,
                appID: appIdentifier?.id,
                appName: app?.attributes?.name,
                bundleID: app?.attributes?.bundleId
            )
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIAppIconsAttributes {
    /// One icon per app ID, from the build Apple chose to include: not always the newest.
    var appIcons: [String: CIAppIcon] {
        var icons: [String: CIAppIcon] = [:]
        for app in data {
            let template = app.relationships("builds").lazy
                .compactMap { includedResource(for: $0)?.attributes?.iconAssetToken?.templateUrl }
                .first
            if let template {
                icons[app.id] = CIAppIcon(templateURL: template)
            }
        }
        return icons
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIBuildIconAttributes {
    /// Builds come newest first: the first one of each app carries its current icon.
    var appIcons: [String: CIAppIcon] {
        var icons: [String: CIAppIcon] = [:]
        for build in data {
            guard let appID = build.relationship("app")?.id, icons[appID] == nil,
                  let template = build.attributes?.iconAssetToken?.templateUrl
            else { continue }
            icons[appID] = CIAppIcon(templateURL: template)
        }
        return icons
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIBuildRunAttributes {
    /// `workflowID` and `workflowName` fill what a response without includes (a created run) does not carry.
    func buildRuns(productID: String, workflowID: String? = nil, workflowName: String? = nil) -> [CIBuildRun] {
        data.map { resource in
            let attributes = resource.attributes
            let workflowIdentifier = resource.relationship("workflow")
            return CIBuildRun(
                id: resource.id,
                productID: productID,
                number: attributes?.number,
                createdDate: attributes?.createdDate,
                startedDate: attributes?.startedDate,
                finishedDate: attributes?.finishedDate,
                executionProgress: CIExecutionProgress(rawValue: attributes?.executionProgress),
                completionStatus: CICompletionStatus(rawValue: attributes?.completionStatus),
                startReason: attributes?.startReason,
                workflowID: workflowIdentifier?.id ?? workflowID,
                workflowName: includedResource(for: workflowIdentifier)?.attributes?.name ?? workflowName,
                sourceBranchOrTag: includedResource(for: resource.relationship("sourceBranchOrTag"))?.attributes?.name,
                issueCounts: attributes?.issueCounts,
                sourceCommit: attributes?.sourceCommit.map {
                    CISourceCommit(commitSha: $0.commitSha, message: $0.message, authorName: $0.author?.displayName, webURL: $0.webUrl)
                },
                cancelReason: attributes?.cancelReason,
                isPullRequestBuild: attributes?.isPullRequestBuild,
                pullRequestNumber: includedResource(for: resource.relationship("pullRequest"))?.attributes?.number,
                pullRequestTitle: includedResource(for: resource.relationship("pullRequest"))?.attributes?.title
            )
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIBuildActionAttributes {
    func buildActions(buildRunID: String) -> [CIBuildAction] {
        data.map { resource in
            let attributes = resource.attributes
            return CIBuildAction(
                id: resource.id,
                buildRunID: buildRunID,
                name: attributes?.name,
                actionType: CIActionType(rawValue: attributes?.actionType),
                startedDate: attributes?.startedDate,
                finishedDate: attributes?.finishedDate,
                executionProgress: CIExecutionProgress(rawValue: attributes?.executionProgress),
                completionStatus: CICompletionStatus(rawValue: attributes?.completionStatus),
                isRequiredToPass: attributes?.isRequiredToPass,
                issueCounts: attributes?.issueCounts
            )
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CITestResultAttributes {
    /// Folds the per-test, per-device results into one entry per device.
    func accumulateDeviceRuns(into runs: inout [String: CITestDeviceRun]) {
        for result in data {
            for destination in result.attributes?.destinationTestResults ?? [] {
                let deviceName = destination.deviceName ?? "?"
                let osVersion = destination.osVersion ?? "?"
                let key = "\(deviceName) (\(osVersion))"
                var run = runs[key] ?? CITestDeviceRun(deviceName: deviceName, osVersion: osVersion)
                run.testCount += 1
                if destination.status == "FAILURE" || destination.status == "MIXED" {
                    run.failedCount += 1
                }
                run.totalSeconds += destination.duration ?? 0
                runs[key] = run
            }
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == CIWorkflowAttributes {
    var workflows: [CIWorkflow] {
        data.map { resource in
            let attributes = resource.attributes
            let repository = includedResource(for: resource.relationship("repository"))?.attributes
            return CIWorkflow(
                id: resource.id,
                name: attributes?.name ?? resource.id,
                testDestinationCounts: (attributes?.actions ?? [])
                    .filter { $0.actionType == "TEST" }
                    .map { $0.testConfiguration?.testDestinations?.count ?? 0 },
                description: attributes?.description,
                isEnabled: attributes?.isEnabled,
                isLockedForEditing: attributes?.isLockedForEditing,
                clean: attributes?.clean,
                containerFilePath: attributes?.containerFilePath,
                lastModifiedDate: attributes?.lastModifiedDate,
                actions: (attributes?.actions ?? []).map {
                    CIWorkflowAction(
                        name: $0.name, actionType: CIActionType(rawValue: $0.actionType), destination: $0.destination,
                        buildDistributionAudience: $0.buildDistributionAudience, scheme: $0.scheme,
                        platform: $0.platform.flatMap(CIPlatform.init(rawValue:)), isRequiredToPass: $0.isRequiredToPass
                    )
                },
                startConditions: attributes.map(CIStartConditions.init(attributes:)),
                xcodeVersionName: versionName(of: includedResource(for: resource.relationship("xcodeVersion"))),
                macOSVersionName: versionName(of: includedResource(for: resource.relationship("macOsVersion"))),
                repositoryName: [repository?.ownerName, repository?.repositoryName].compactMap(\.self).joined(separator: "/").nilIfEmpty,
                xcodeVersion: includedResource(for: resource.relationship("xcodeVersion"))?.attributes?.version,
                xcodeVersionID: resource.relationship("xcodeVersion")?.id,
                macOSVersionID: resource.relationship("macOsVersion")?.id
            )
        }
    }

    private func versionName(of resource: JSONAPIIncludedResource?) -> String? {
        let attributes = resource?.attributes
        switch (attributes?.name, attributes?.version) {
        case let (name?, version?): return name.contains(version) ? name : "\(name) (\(version))"
        case let (name?, nil): return name
        case let (nil, version?): return version
        case (nil, nil): return nil
        }
    }
}

nonisolated extension CIStartConditions {
    init(attributes: CIWorkflowAttributes) {
        self.init(
            branches: attributes.branchStartCondition?.source?.model,
            tags: attributes.tagStartCondition?.source?.model,
            pullRequests: attributes.pullRequestStartCondition?.source?.model,
            scheduleFrequency: attributes.scheduledStartCondition?.schedule?.frequency.flatMap(CIScheduleFrequency.init(rawValue:)),
            schedule: CISchedule(attributes: attributes.scheduledStartCondition?.schedule, source: attributes.scheduledStartCondition?.source),
            filesRule: (attributes.branchStartCondition ?? attributes.pullRequestStartCondition ?? attributes.tagStartCondition)?
                .filesAndFoldersRule?.mode.flatMap(CIFilesRuleMode.init(rawValue:)),
            autoCancel: (attributes.branchStartCondition ?? attributes.pullRequestStartCondition ?? attributes.tagStartCondition)?.autoCancel,
            manualBranches: attributes.manualBranchStartCondition?.source?.model,
            manualTags: attributes.manualTagStartCondition?.source?.model,
            manualPullRequests: attributes.manualPullRequestStartCondition?.source?.model
        )
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
