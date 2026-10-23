import Foundation
import Observation

/// Gives a TestFlight build to groups of testers and takes it from others (the fourth kind of write the app makes at Apple),
/// and expires a build (the fifth).
/// Each request is sent once and never repeated, whatever came back; a write Apple did not confirm is followed by a read of
/// the build, not by a second try. The card and, later, the `cumulus` command call `distribute` the same way.
@Observable
final class TestFlightDistributor {
    private(set) var isSending = false
    private let client: () async -> AppStoreConnectClient?
    /// Reads the build again and keeps it where the app keeps its TestFlight builds; nil when it could not be read.
    private let reread: @MainActor (String) async -> TestFlightBuild?
    /// Cumulus Pro: false sends nothing and reads nothing.
    @ObservationIgnored var allowed: @MainActor () -> Bool
    /// The account's “Key access”: a key set to read only sends nothing.
    @ObservationIgnored var isKeyWritable: @MainActor () -> Bool

    init(
        client: @escaping () async -> AppStoreConnectClient?, reread: @escaping @MainActor (String) async -> TestFlightBuild?,
        allowed: @escaping @MainActor () -> Bool = { true }, isKeyWritable: @escaping @MainActor () -> Bool = { true }
    ) {
        self.client = client
        self.reread = reread
        self.allowed = allowed
        self.isKeyWritable = isKeyWritable
    }

    /// The test notes Apple holds for a build, one per language; nil when they could not be read.
    func notes(for buildID: String) async -> [BetaBuildNote]? {
        guard allowed(), let client = await client() else { return nil }
        return try? await client.betaBuildNotes(buildID: buildID)
    }

    /// Whether the build, as Apple has it after its groups were added, has to be sent to the beta review: an external group
    /// was added and no submission exists. This is the one place that decides it. Whether Apple files the submission by
    /// itself when an external group is added has not been seen on a real account; the cautious reading is that it does not,
    /// but a build that already has a submission or is already in external testing is never sent again.
    static func needsBetaReview(_ build: TestFlightBuild?) -> Bool {
        guard let build else { return false }
        return build.review == nil && build.externalState == .readyForSubmission
    }

    func distribute(_ request: DistributionRequest) async -> DistributionOutcome {
        guard allowed() else { return .failed(message: ProFeatureText.required, completed: []) }
        guard isKeyWritable() else { return .notAllowed(message: DistributionOutcome.readOnlyMessage, completed: []) }
        // A second tap while the first is in flight must not send a second request.
        guard !isSending else { return .failed(message: String(localized: "A distribution is already in progress."), completed: []) }
        var writes = request.writes
        guard !writes.isEmpty else { return .failed(message: String(localized: "There is nothing to change."), completed: []) }
        guard writes.allSatisfy(\.isWellFormed) else { return .failed(message: AppStoreConnectError.invalidResponse.message, completed: []) }
        isSending = true
        defer { isSending = false }
        guard let client = await client() else { return .failed(message: String(localized: "No API key is set up."), completed: []) }

        var completed: [DistributionStep] = []
        var index = 0
        while index < writes.count {
            let write = writes[index]
            index += 1
            do {
                try await send(write, with: client)
                completed.append(write.step)
            } catch {
                return await stopped(by: error, at: write.step, completed: completed, buildID: request.build.id)
            }
            if write.step == .addGroups, request.addsExternalGroup {
                // Added to an external group: read the build to see whether a beta review submission exists before asking for one.
                let after = await reread(request.build.id)
                if Self.needsBetaReview(after) {
                    writes.append(.betaReview(BetaReviewSubmissionRequest(buildID: request.build.id)))
                }
            }
        }
        return .accepted(completed: completed, build: await reread(request.build.id))
    }

    /// Gives the build to groups like `distribute`, then, only if Apple accepted that, expires the previous build. An expiration
    /// that fails leaves the new build as it is.
    func distribute(_ request: DistributionRequest, thenExpiring previousID: String?) async -> DistributionResult {
        let outcome = await distribute(request)
        guard let previousID, previousID != request.build.id, outcome.isAccepted else {
            return DistributionResult(distribution: outcome, expiration: nil)
        }
        return DistributionResult(distribution: outcome, expiration: await expire(buildID: previousID))
    }

    /// Makes a build unavailable for testing, for good. One `PATCH`, never repeated: an answer that does not say whether it
    /// went through is followed by a read of the build, and a build that reads as expired is an expired build.
    func expire(buildID: String) async -> ExpirationOutcome {
        guard allowed() else { return .failed(message: ProFeatureText.required) }
        guard isKeyWritable() else { return .notAllowed(message: DistributionOutcome.readOnlyMessage) }
        guard !isSending else { return .failed(message: String(localized: "A distribution is already in progress.")) }
        let request = BuildExpirationRequest(buildID: buildID)
        guard request.isWellFormed else { return .failed(message: AppStoreConnectError.invalidResponse.message) }
        isSending = true
        defer { isSending = false }
        guard let client = await client() else { return .failed(message: String(localized: "No API key is set up.")) }
        do {
            try await client.expireBuild(request)
        } catch {
            switch LaunchOutcome.classify(error) {
            case .notAllowed?: return .notAllowed(message: ExpirationOutcome.forbiddenMessage)
            case .refused(let message, _)?: return .refused(message: message)
            case .rateLimited?: return .rateLimited
            case .failed(let message)?: return .failed(message: message)
            case .started?, .accepted?, .uncertain?, .unknown?, nil:
                let build = await reread(buildID)
                return build?.isMarkedExpired == true ? .expired(build: build) : .uncertain(build: build)
            }
        }
        return .expired(build: await reread(buildID))
    }

    private func send(_ write: DistributionWrite, with client: AppStoreConnectClient) async throws(AppStoreConnectError) {
        switch write {
        case .notes(let note): try await client.writeBetaNote(note)
        case .notification(let request): try await client.setAutoNotify(request)
        case .add(let request): try await client.addBetaGroups(request)
        case .remove(let request): try await client.removeBetaGroups(request)
        case .betaReview(let request): try await client.submitForBetaReview(request)
        }
    }

    private func stopped(by error: AppStoreConnectError, at step: DistributionStep, completed: [DistributionStep], buildID: String) async -> DistributionOutcome {
        let outcome: DistributionOutcome
        switch LaunchOutcome.classify(error) {
        case .notAllowed?: outcome = .notAllowed(message: DistributionOutcome.forbiddenMessage, completed: completed)
        case .refused(let message, _)?: outcome = .refused(message: message, step: step, completed: completed)
        case .rateLimited?: return .rateLimited(completed: completed)
        case .failed(let message)?: outcome = .failed(message: message, completed: completed)
        case .started?, .accepted?, .uncertain?, .unknown?, nil:
            // The request may have reached Apple: the build tells what happened, before anyone tries again.
            return .uncertain(step: step, completed: completed, build: await reread(buildID))
        }
        // Something was accepted before the stop: the card must show it, so the build is read back as well.
        if !completed.isEmpty { _ = await reread(buildID) }
        return outcome
    }
}
