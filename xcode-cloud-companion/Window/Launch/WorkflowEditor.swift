import Foundation
import Observation

/// How a change of workflow ended. `saved` and `uncertain` carry what Apple says the workflow is, never what was asked for.
nonisolated enum WorkflowEditOutcome: Equatable, Sendable {
    case saved(CIWorkflow)
    /// 403: the key may not change workflows.
    case notAllowed(message: String)
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String)
    case rateLimited
    case failed(message: String)
    /// Apple did not confirm. The workflow is what a fresh read says; nil when that read failed too.
    case uncertain(CIWorkflow?)

    /// What the sheet says when it stays open; nil when the change is known to be applied.
    var message: String? {
        switch self {
        case .saved: nil
        case .uncertain(nil):
            String(localized: "Apple did not confirm the change, and the workflow could not be read back. Check it in App Store Connect before trying again.")
        case .uncertain:
            String(localized: "Apple did not confirm the change. The sheet now shows the workflow as Apple has it; look it over before trying again.")
        case .notAllowed(let message), .refused(let message), .failed(let message): message
        case .rateLimited: String(localized: "Apple’s hourly request limit is reached. Nothing was changed; try again later.")
        }
    }
}

/// Changes a workflow's name, description, Xcode, macOS and clean setting, once: the third kind of write the app makes.
/// The request is never repeated, whatever came back; an unconfirmed change is followed by a read, not by a second try.
@Observable
final class WorkflowEditor {
    private(set) var isSending = false
    /// nil until read; stays nil when the read failed, which is not the same as an empty list.
    private(set) var xcodeVersions: [CIXcodeVersion]?
    private(set) var macOSVersionsByXcode: [String: [CIMacOSVersion]] = [:]
    private(set) var versionsFailed = false
    private let client: () async -> AppStoreConnectClient?
    private let budget: () async -> RateLimit?
    /// Hands Apple's answer to whatever shows workflows.
    private let applied: @MainActor (CIWorkflow) async -> Void

    init(client: @escaping () async -> AppStoreConnectClient?, budget: @escaping () async -> RateLimit?, applied: @escaping @MainActor (CIWorkflow) async -> Void) {
        self.client = client
        self.budget = budget
        self.applied = applied
    }

    /// The Xcode versions, once per session, and the macOS versions of the one the workflow uses; nothing when the key's budget is nearly spent.
    func loadVersions(currentXcodeVersionID: String?) async {
        if xcodeVersions == nil {
            guard let client = await client() else { return }
            if let left = await budget(), left.remaining <= SyncSchedule.criticalRemaining { return }
            if let fetched = try? await client.xcodeVersions() {
                xcodeVersions = fetched
                versionsFailed = false
            } else {
                versionsFailed = true
            }
        }
        if let currentXcodeVersionID {
            await loadMacOSVersions(xcodeVersionID: currentXcodeVersionID)
        }
    }

    func loadMacOSVersions(xcodeVersionID: String) async {
        guard macOSVersionsByXcode[xcodeVersionID] == nil, let client = await client() else { return }
        if let fetched = try? await client.macOSVersions(xcodeVersionID: xcodeVersionID) {
            macOSVersionsByXcode[xcodeVersionID] = fetched
        }
    }

    /// Newest public version first, then the rest from newest to oldest.
    static func ordered(_ versions: [CIXcodeVersion]) -> [CIXcodeVersion] {
        let latest = XcodeVersionCheck.latestPublic(in: versions)
        let rest = versions.filter { $0.id != latest?.id }.sorted { XcodeVersionCheck.compare($0.version, $1.version) == .orderedDescending }
        return [latest].compactMap(\.self) + rest
    }

    func save(_ request: WorkflowUpdateRequest, workflow: CIWorkflow) async -> WorkflowEditOutcome {
        // A second click while the first is in flight must not send a second request.
        guard !isSending else { return .failed(message: String(localized: "A change is already in progress.")) }
        guard workflow.isLockedForEditing != true else { return .failed(message: Self.lockedMessage) }
        guard request.isWellFormed else { return .failed(message: AppStoreConnectError.invalidResponse.message) }
        isSending = true
        defer { isSending = false }
        guard let client = await client() else { return .failed(message: String(localized: "No API key is set up.")) }

        do {
            let answered = try await client.updateWorkflow(request)
            // The answer names the versions by id only: their names come from the lists the sheet read.
            guard let answered else {
                let read = await reread(workflow, client: client)
                return .uncertain(read)
            }
            let merged = merged(answered, into: workflow)
            await applied(merged)
            return .saved(merged)
        } catch {
            switch LaunchOutcome.classify(error) {
            case .notAllowed(let message)?: return .notAllowed(message: message)
            case .refused(let message, _)?: return .refused(message: message)
            case .rateLimited?: return .rateLimited
            case .failed(let message)?: return .failed(message: message)
            case .started?, .accepted?, .uncertain?, .unknown?, nil:
                // The request may have reached Apple: the workflow tells what happened, before anyone tries again.
                return .uncertain(await reread(workflow, client: client))
            }
        }
    }

    static var lockedMessage: String {
        String(localized: "This workflow is locked for editing in App Store Connect: it can’t be changed from here.")
    }

    private func reread(_ workflow: CIWorkflow, client: AppStoreConnectClient) async -> CIWorkflow? {
        guard let read = try? await client.workflow(id: workflow.id) else { return nil }
        let merged = merged(read, into: workflow)
        await applied(merged)
        return merged
    }

    /// Apple's answer over the workflow as it was, the versions named from the lists when the answer gives ids alone.
    func merged(_ answer: CIWorkflow, into workflow: CIWorkflow) -> CIWorkflow {
        var named = answer
        if named.xcodeVersionName == nil, let id = named.xcodeVersionID, let version = xcodeVersions?.first(where: { $0.id == id }) {
            named.xcodeVersionName = version.name
            named.xcodeVersion = version.version
        }
        if named.macOSVersionName == nil, let id = named.macOSVersionID, let version = macOSVersionsByXcode.values.joined().first(where: { $0.id == id }) {
            named.macOSVersionName = version.name
        }
        var result = workflow
        result.adopt(named)
        return result
    }
}
