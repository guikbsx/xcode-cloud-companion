import Foundation
import os

nonisolated struct GitReference: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case branch, tag
    }

    let id: String
    let name: String
    let kind: Kind
}

/// A pull request Xcode Cloud can build, as the launch sheet offers it. Shared with the `cumulus` command, like `GitReference`.
nonisolated struct PullRequestReference: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let title: String
    let sourceBranch: String?
    let destinationBranch: String?
    let isCrossRepository: Bool
    let webURL: URL?

    /// “#128 Add the cycle widget”, or “#128” when the host gave no title.
    var label: String {
        title.isEmpty ? "#\(number)" : "#\(number) \(title)"
    }
}

/// What a launched build runs on: one branch or tag, or one pull request. Never both.
nonisolated enum LaunchSource: Equatable, Sendable {
    case gitReference(id: String)
    case pullRequest(id: String)
}

/// A request to start or rebuild a run. The shapes are the ones Apple's open source clients send; the app only builds valid ones:
/// a launch names a workflow and exactly one source, a rebuild names the run it repeats and sends no source.
nonisolated struct BuildRunRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case launch(workflowID: String, source: LaunchSource)
        case rebuild(workflowID: String, buildRunID: String)
    }

    let kind: Kind
    /// Sent only when true: a clean build is asked for, never refused with `false`.
    let clean: Bool

    var workflowID: String {
        switch kind {
        case .launch(let workflowID, _), .rebuild(let workflowID, _): workflowID
        }
    }

    static func launch(workflowID: String, source: LaunchSource, clean: Bool = false) -> BuildRunRequest {
        BuildRunRequest(kind: .launch(workflowID: workflowID, source: source), clean: clean)
    }

    static func rebuild(buildRunID: String, workflowID: String, clean: Bool = false) -> BuildRunRequest {
        BuildRunRequest(kind: .rebuild(workflowID: workflowID, buildRunID: buildRunID), clean: clean)
    }

    /// Identifiers go into a JSON body, not a path, but they are still only letters, digits and hyphens.
    var isWellFormed: Bool {
        func ok(_ id: String) -> Bool {
            !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        switch kind {
        case .launch(let workflowID, .gitReference(let id)), .launch(let workflowID, .pullRequest(let id)):
            return ok(workflowID) && ok(id)
        case .rebuild(let workflowID, let buildRunID):
            return ok(workflowID) && ok(buildRunID)
        }
    }

    func body() throws -> Data {
        func relation(_ type: String, _ id: String) -> [String: Any] {
            ["data": ["type": type, "id": id]]
        }
        var relationships: [String: Any] = [:]
        switch kind {
        case .launch(let workflowID, let source):
            relationships["workflow"] = relation("ciWorkflows", workflowID)
            switch source {
            case .gitReference(let id): relationships["sourceBranchOrTag"] = relation("scmGitReferences", id)
            case .pullRequest(let id): relationships["pullRequest"] = relation("scmPullRequests", id)
            }
        case .rebuild(let workflowID, let buildRunID):
            relationships["workflow"] = relation("ciWorkflows", workflowID)
            relationships["buildRun"] = relation("ciBuildRuns", buildRunID)
        }
        var data: [String: Any] = ["type": "ciBuildRuns", "relationships": relationships]
        if clean {
            data["attributes"] = ["clean": true]
        }
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

/// A request to pause or resume a workflow. `isEnabled` is the only attribute it carries: nothing else of the workflow can change.
nonisolated struct WorkflowStateRequest: Equatable, Sendable {
    let workflowID: String
    let isEnabled: Bool

    var isWellFormed: Bool {
        !workflowID.isEmpty && workflowID.count <= 64 && workflowID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    func body() throws -> Data {
        let data: [String: Any] = ["type": "ciWorkflows", "id": workflowID, "attributes": ["isEnabled": isEnabled]]
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }
}

nonisolated struct CIRepositoryAttributes: Decodable, Sendable {
    let ownerName: String?
    let repositoryName: String?
}

nonisolated struct SCMGitReferenceAttributes: Decodable, Sendable {
    let name: String?
    let canonicalName: String?
    let isDeleted: Bool?
    let kind: String?
}

nonisolated struct SCMPullRequestAttributes: Decodable, Sendable {
    let title: String?
    let number: Int?
    let isClosed: Bool?
    let isCrossRepository: Bool?
    let sourceBranchName: String?
    let destinationBranchName: String?
    let webUrl: String?
}

nonisolated extension JSONAPIDocument where Attributes == SCMPullRequestAttributes {
    /// Open pull requests only: a closed one cannot be built.
    var pullRequests: [PullRequestReference] {
        data.compactMap { resource in
            guard let attributes = resource.attributes, let number = attributes.number, attributes.isClosed != true else { return nil }
            let webURL = attributes.webUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            return PullRequestReference(
                id: resource.id, number: number, title: attributes.title ?? "",
                sourceBranch: attributes.sourceBranchName, destinationBranch: attributes.destinationBranchName,
                isCrossRepository: attributes.isCrossRepository ?? false, webURL: webURL
            )
        }
    }
}

nonisolated extension JSONAPIDocument where Attributes == SCMGitReferenceAttributes {
    /// Live branches and tags, branches first, each group by name.
    var gitReferences: [GitReference] {
        data.compactMap { resource in
            guard let name = resource.attributes?.name, resource.attributes?.isDeleted != true else { return nil }
            return GitReference(id: resource.id, name: name, kind: resource.attributes?.kind == "TAG" ? .tag : .branch)
        }
    }
}

/// The least a 2xx answer to a creation says: the id of what was created.
private nonisolated struct CreatedResource: Decodable {
    struct Resource: Decodable {
        let id: String
    }

    let data: Resource
}

/// What went wrong around a launch goes to the system log (`log show --predicate 'subsystem == "com.guik.xcode-cloud-companion"'`):
/// a launch costs a build, so nobody reproduces one to learn why its answer was not understood.
nonisolated enum LaunchLog {
    private static let logger = Logger(subsystem: "com.guik.xcode-cloud-companion", category: "launch")

    /// Apple answered 2xx and its body did not decode. The reason names fields, never a credential.
    static func unreadableAnswer(_ reason: String) {
        logger.error("Apple accepted the launch (2xx) but its answer did not decode: \(reason, privacy: .public)")
    }

    static func unconfirmed(_ error: AppStoreConnectError, outcome: String) {
        logger.error("Launch not confirmed by Apple (\(String(describing: error), privacy: .public)); after reading the build list: \(outcome, privacy: .public)")
    }
}

extension AppStoreConnectClient {
    /// Starts or rebuilds a run. One request, never repeated: a second one could start a second build.
    func startBuildRun(_ request: BuildRunRequest, productID: String, workflowName: String?) async throws(AppStoreConnectError) -> CIBuildRun {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        var urlRequest = URLRequest(url: AppStoreConnectEndpoint.createBuildRun, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        // From here on Apple said yes: the build exists, whatever can be read of the answer.
        let data = try await accepted(urlRequest)
        do {
            let document = try JSONDecoder.appStoreConnect.decode(JSONAPISingleDocument<CIBuildRunAttributes>.self, from: data)
            return JSONAPIDocument(single: document).buildRuns(productID: productID, workflowID: request.workflowID, workflowName: workflowName)[0]
        } catch {
            let reason = String(describing: error)
            LaunchLog.unreadableAnswer(reason)
            // Its id is enough to know the run; the next sync reads the rest.
            guard let id = (try? JSONDecoder().decode(CreatedResource.self, from: data))?.data.id else { throw .decoding(reason) }
            return CIBuildRun(
                id: id, productID: productID, number: nil, createdDate: now(), startedDate: nil, finishedDate: nil, executionProgress: .pending,
                completionStatus: nil, startReason: "MANUAL", workflowID: request.workflowID, workflowName: workflowName, sourceBranchOrTag: nil
            )
        }
    }

    /// Pauses or resumes a workflow. One request, never repeated. Returns the state Apple answers with, nil if it says none.
    func setWorkflowEnabled(_ request: WorkflowStateRequest) async throws(AppStoreConnectError) -> Bool? {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        var urlRequest = URLRequest(url: AppStoreConnectEndpoint.updateWorkflow(id: request.workflowID), timeoutInterval: 30)
        urlRequest.httpMethod = "PATCH"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let document: JSONAPISingleDocument<CIWorkflowAttributes> = try await send(urlRequest)
        return document.data.attributes?.isEnabled
    }

    /// Whether the workflow is enabled, as Apple has it now.
    func workflowIsEnabled(workflowID: String) async throws(AppStoreConnectError) -> Bool? {
        let document: JSONAPISingleDocument<CIWorkflowAttributes> = try await decoded(at: AppStoreConnectEndpoint.workflowState(id: workflowID))
        return document.data.attributes?.isEnabled
    }

    func repositoryID(workflowID: String) async throws(AppStoreConnectError) -> String {
        let document: JSONAPISingleDocument<CIRepositoryAttributes> = try await decoded(at: AppStoreConnectEndpoint.workflowRepository(workflowID: workflowID))
        return document.data.id
    }

    func gitReferences(repositoryID: String, maxPages: Int = 3) async throws(AppStoreConnectError) -> [GitReference] {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.gitReferences(repositoryID: repositoryID), of: SCMGitReferenceAttributes.self, maxPages: maxPages)
        let all = pages.flatMap(\.gitReferences)
        let order: (GitReference, GitReference) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return all.filter { $0.kind == .branch }.sorted(by: order) + all.filter { $0.kind == .tag }.sorted(by: order)
    }

    /// The repository's open pull requests, newest first.
    func pullRequests(repositoryID: String, maxPages: Int = 2) async throws(AppStoreConnectError) -> [PullRequestReference] {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.pullRequests(repositoryID: repositoryID), of: SCMPullRequestAttributes.self, maxPages: maxPages)
        return pages.flatMap(\.pullRequests).sorted { $0.number > $1.number }
    }

    func latestBuildRun(workflowID: String, productID: String) async throws(AppStoreConnectError) -> CIBuildRun? {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.latestBuildRun(workflowID: workflowID), of: CIBuildRunAttributes.self, maxPages: 1)
        return pages.first?.buildRuns(productID: productID).first
    }
}
