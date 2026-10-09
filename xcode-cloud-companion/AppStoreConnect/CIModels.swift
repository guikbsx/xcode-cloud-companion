import Foundation

nonisolated struct CIProduct: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let productType: String?
    let appID: String?
    let appName: String?
    let bundleID: String?
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
    let name: String
    /// Destinations configured on each test action, in the workflow's order.
    let testDestinationCounts: [Int]
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
}

nonisolated struct CIBuildActionAttributes: Decodable, Sendable {
    let name: String?
    let actionType: String?
    let startedDate: Date?
    let finishedDate: Date?
    let executionProgress: String?
    let completionStatus: String?
    let isRequiredToPass: Bool?
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

nonisolated struct CIWorkflowAttributes: Decodable, Sendable {
    let name: String?
    let actions: [Action]?

    struct Action: Decodable, Sendable {
        let actionType: String?
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

nonisolated extension JSONAPIDocument where Attributes == CIBuildRunAttributes {
    func buildRuns(productID: String) -> [CIBuildRun] {
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
                workflowID: workflowIdentifier?.id,
                workflowName: includedResource(for: workflowIdentifier)?.attributes?.name,
                sourceBranchOrTag: includedResource(for: resource.relationship("sourceBranchOrTag"))?.attributes?.name
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
                isRequiredToPass: attributes?.isRequiredToPass
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
            CIWorkflow(
                id: resource.id,
                name: resource.attributes?.name ?? resource.id,
                testDestinationCounts: (resource.attributes?.actions ?? [])
                    .filter { $0.actionType == "TEST" }
                    .map { $0.testConfiguration?.testDestinations?.count ?? 0 }
            )
        }
    }
}
