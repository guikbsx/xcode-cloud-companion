import Foundation

nonisolated struct CIProduct: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let productType: String?
    let appID: String?
    let appName: String?
    let bundleID: String?
}

nonisolated struct CIBuildRun: Sendable, Equatable, Identifiable {
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

nonisolated struct CIBuildAction: Sendable, Equatable, Identifiable {
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
