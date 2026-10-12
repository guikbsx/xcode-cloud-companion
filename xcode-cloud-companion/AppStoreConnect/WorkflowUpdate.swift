import Foundation

/// A macOS version Xcode Cloud offers for a given Xcode.
nonisolated struct CIMacOSVersion: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
}

nonisolated struct CIMacOSVersionAttributes: Decodable, Sendable {
    let name: String?
    let version: String?
}

nonisolated extension JSONAPIDocument where Attributes == CIMacOSVersionAttributes {
    var macOSVersions: [CIMacOSVersion] {
        data.compactMap { resource in
            guard let version = resource.attributes?.version else { return nil }
            return CIMacOSVersion(id: resource.id, name: resource.attributes?.name ?? "macOS \(version)", version: version)
        }
    }
}

/// The third write the app makes: a `PATCH` on a workflow that carries only what changed, so that nothing Apple holds
/// is sent back and overwritten. Triggers, actions and environment variables are never touched.
nonisolated struct WorkflowUpdateRequest: Equatable, Sendable {
    let workflowID: String
    var name: String?
    var description: String?
    var clean: Bool?
    var xcodeVersionID: String?
    var macOSVersionID: String?

    var isEmpty: Bool {
        name == nil && description == nil && clean == nil && xcodeVersionID == nil && macOSVersionID == nil
    }

    var isWellFormed: Bool {
        [workflowID, xcodeVersionID, macOSVersionID].compactMap(\.self).allSatisfy(Self.isIdentifier) && !isEmpty
            && name.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
    }

    /// What differs between the workflow as Apple has it and the fields of the sheet; empty when nothing changed.
    static func changes(from workflow: CIWorkflow, name: String, description: String, clean: Bool, xcodeVersionID: String?, macOSVersionID: String?) -> WorkflowUpdateRequest {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowUpdateRequest(
            workflowID: workflow.id,
            name: name == workflow.name ? nil : name,
            description: description == (workflow.description ?? "") ? nil : description,
            clean: clean == (workflow.clean ?? false) ? nil : clean,
            xcodeVersionID: xcodeVersionID == workflow.xcodeVersionID ? nil : xcodeVersionID,
            macOSVersionID: macOSVersionID == workflow.macOSVersionID ? nil : macOSVersionID
        )
    }

    func body() throws -> Data {
        var attributes: [String: Any] = [:]
        if let name { attributes["name"] = name }
        if let description { attributes["description"] = description }
        if let clean { attributes["clean"] = clean }
        var relationships: [String: Any] = [:]
        if let xcodeVersionID { relationships["xcodeVersion"] = ["data": ["type": "ciXcodeVersions", "id": xcodeVersionID]] }
        if let macOSVersionID { relationships["macOsVersion"] = ["data": ["type": "ciMacOsVersions", "id": macOSVersionID]] }
        var data: [String: Any] = ["type": "ciWorkflows", "id": workflowID]
        if !attributes.isEmpty { data["attributes"] = attributes }
        if !relationships.isEmpty { data["relationships"] = relationships }
        return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

nonisolated extension CIWorkflow {
    /// Takes what a change at Apple's gave back, and keeps the rest (actions, conditions, repository) as it was.
    mutating func adopt(_ changed: CIWorkflow) {
        name = changed.name
        description = changed.description
        clean = changed.clean
        containerFilePath = changed.containerFilePath ?? containerFilePath
        lastModifiedDate = changed.lastModifiedDate ?? lastModifiedDate
        isEnabled = changed.isEnabled ?? isEnabled
        isLockedForEditing = changed.isLockedForEditing ?? isLockedForEditing
        xcodeVersionID = changed.xcodeVersionID ?? xcodeVersionID
        xcodeVersionName = changed.xcodeVersionName ?? xcodeVersionName
        xcodeVersion = changed.xcodeVersion ?? xcodeVersion
        macOSVersionID = changed.macOSVersionID ?? macOSVersionID
        macOSVersionName = changed.macOSVersionName ?? macOSVersionName
    }
}

extension AppStoreConnectClient {
    /// Changes a workflow. One request, never repeated. Returns the workflow as Apple answers it, without the versions'
    /// names: the answer names its relationships, not the resources behind them.
    func updateWorkflow(_ request: WorkflowUpdateRequest) async throws(AppStoreConnectError) -> CIWorkflow? {
        guard request.isWellFormed, let body = try? request.body() else { throw .invalidResponse }
        var urlRequest = URLRequest(url: AppStoreConnectEndpoint.updateWorkflow(id: request.workflowID), timeoutInterval: 30)
        urlRequest.httpMethod = "PATCH"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let document: JSONAPISingleDocument<CIWorkflowAttributes> = try await send(urlRequest)
        return JSONAPIDocument(single: document).workflows.first
    }

    /// One workflow with its versions, as Apple has it now: what an unconfirmed change did.
    func workflow(id: String) async throws(AppStoreConnectError) -> CIWorkflow? {
        let document: JSONAPISingleDocument<CIWorkflowAttributes> = try await decoded(at: AppStoreConnectEndpoint.workflowDetail(id: id))
        return JSONAPIDocument(single: document).workflows.first
    }

    func macOSVersions(xcodeVersionID: String) async throws(AppStoreConnectError) -> [CIMacOSVersion] {
        let pages = try await collectPages(from: AppStoreConnectEndpoint.macOSVersions(xcodeVersionID: xcodeVersionID), of: CIMacOSVersionAttributes.self, maxPages: 1)
        return pages.flatMap(\.macOSVersions)
    }
}
