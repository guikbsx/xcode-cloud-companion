import Foundation
import Observation

/// How a pause or a resume ended. `changed` and `uncertain` carry what Apple says the state is, never what was asked for.
nonisolated enum WorkflowStateOutcome: Equatable, Sendable {
    case changed(isEnabled: Bool)
    /// 403: the key may not change workflows.
    case notAllowed(message: String)
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String)
    case rateLimited
    case failed(message: String)
    /// Apple did not confirm. `isEnabled` is what a fresh read says; nil when that read failed too.
    case uncertain(isEnabled: Bool?)

    /// What the confirmation sheet says when it stays open; nil when the workflow is in the state that was asked for.
    func message(wanted: Bool) -> String? {
        switch self {
        case .changed(let isEnabled), .uncertain(let isEnabled?):
            guard isEnabled != wanted else { return nil }
            return isEnabled
                ? String(localized: "Apple reports this workflow as still enabled. Nothing changed; you can try again.")
                : String(localized: "Apple reports this workflow as still paused. Nothing changed; you can try again.")
        case .uncertain(nil):
            return String(localized: "Apple did not confirm the change, and the workflow’s state could not be read. Check it in App Store Connect before trying again.")
        case .notAllowed(let message), .refused(let message), .failed(let message):
            return message
        case .rateLimited:
            return String(localized: "Apple’s hourly request limit is reached. Nothing was changed; try again later.")
        }
    }
}

/// Pauses or resumes a workflow, once: the second and last kind of write the app makes at Apple, after launching a build.
/// The request is never repeated, whatever came back; an unconfirmed change is followed by a read, not by a second try.
@Observable
final class WorkflowPauser {
    private(set) var isSending = false
    private let client: () async -> AppStoreConnectClient?
    /// Hands Apple's answer to whatever shows workflows: the workflow, and whether it is enabled.
    private let applied: @MainActor (String, Bool) async -> Void

    init(client: @escaping () async -> AppStoreConnectClient?, applied: @escaping @MainActor (String, Bool) async -> Void) {
        self.client = client
        self.applied = applied
    }

    func setEnabled(_ isEnabled: Bool, workflow: CIWorkflow) async -> WorkflowStateOutcome {
        // A second tap while the first is in flight must not send a second request.
        guard !isSending else { return .failed(message: String(localized: "A change is already in progress.")) }
        guard workflow.isLockedForEditing != true else { return .failed(message: Self.lockedMessage) }
        let request = WorkflowStateRequest(workflowID: workflow.id, isEnabled: isEnabled)
        guard request.isWellFormed else { return .failed(message: AppStoreConnectError.invalidResponse.message) }
        isSending = true
        defer { isSending = false }
        guard let client = await client() else { return .failed(message: String(localized: "No API key is set up.")) }

        do {
            // The state shown afterwards is the one in Apple's answer; if it gives none, it is read, not assumed.
            let answered = try await client.setWorkflowEnabled(request)
            guard let state = await known(answered, workflowID: workflow.id, client: client) else { return .uncertain(isEnabled: nil) }
            await applied(workflow.id, state)
            return .changed(isEnabled: state)
        } catch {
            switch LaunchOutcome.classify(error) {
            case .notAllowed(let message)?: return .notAllowed(message: message)
            case .refused(let message, _)?: return .refused(message: message)
            case .rateLimited?: return .rateLimited
            case .failed(let message)?: return .failed(message: message)
            case .started?, .uncertain?, nil:
                // The request may have reached Apple: the workflow tells what happened, before anyone tries again.
                let state = await known(nil, workflowID: workflow.id, client: client)
                if let state {
                    await applied(workflow.id, state)
                }
                return .uncertain(isEnabled: state)
            }
        }
    }

    static var lockedMessage: String {
        String(localized: "This workflow is locked for editing in App Store Connect: it can’t be paused or resumed from here.")
    }

    private func known(_ answered: Bool?, workflowID: String, client: AppStoreConnectClient) async -> Bool? {
        if let answered { return answered }
        return (try? await client.workflowIsEnabled(workflowID: workflowID)) ?? nil
    }
}
