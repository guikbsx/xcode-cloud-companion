import Foundation

/// What checking and unchecking groups would change for a build: the groups to give it to, and the ones to take it from.
/// A group that gets every build is not a choice, so it is never in either list.
nonisolated struct TestFlightDistributionPlan: Sendable, Equatable {
    var toAdd: [BetaGroup]
    var toRemove: [BetaGroup]

    var isEmpty: Bool { toAdd.isEmpty && toRemove.isEmpty }

    /// An external group needs Apple's beta review before its testers get the build.
    var addsExternalGroup: Bool { toAdd.contains { !$0.isInternal } }

    static func make(groups: [BetaGroup], members: Set<String>, selected: Set<String>) -> TestFlightDistributionPlan {
        let choices = groups.filter { !$0.receivesEveryBuild }
        return TestFlightDistributionPlan(
            toAdd: choices.filter { selected.contains($0.id) && !members.contains($0.id) },
            toRemove: choices.filter { !selected.contains($0.id) && members.contains($0.id) }
        )
    }

    /// The groups the build is in: those Apple lists for it, and the ones that get every build, which Apple does not always list.
    static func members(of build: TestFlightBuild, in groups: [BetaGroup]) -> Set<String> {
        build.memberGroupIDs(in: groups)
    }
}

/// The test notes of one language as the sheet holds them, with what Apple already has for that language.
nonisolated struct DistributionNotes: Sendable, Equatable {
    var locale: String
    var text: String
    /// Apple's notes for `locale`, if it has any.
    var existing: BetaBuildNote?

    /// Written only when they differ from Apple's, with no stray blank lines at the ends; text on a language that has none is a creation.
    func request(buildID: String) -> BetaNoteRequest? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            guard wanted != existing.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return BetaNoteRequest(buildID: buildID, kind: .update(localizationID: existing.id), text: wanted)
        }
        guard !wanted.isEmpty else { return nil }
        return BetaNoteRequest(buildID: buildID, kind: .create(locale: locale), text: wanted)
    }
}

/// Everything one “Give access” asks of Apple: the groups to give the build to and to take it from, the notes, and whether
/// the testers are told. Whoever sends it (the card, later the `cumulus` command) hands over the same thing.
nonisolated struct DistributionRequest: Sendable, Equatable {
    var build: TestFlightBuild
    var add: [BetaGroup] = []
    var remove: [BetaGroup] = []
    var notes: DistributionNotes?
    /// Whether Apple tells the testers when the build reaches them; nil leaves the build's setting as it is.
    var notify: Bool?

    /// The writes in the order they are sent: the notes first, so the testers read them when they get the build, then the
    /// notification setting, then the groups. The beta review request is not here: it is decided after the groups are added.
    var writes: [DistributionWrite] {
        var writes: [DistributionWrite] = []
        if let note = notes?.request(buildID: build.id) { writes.append(.notes(note)) }
        if let notify, notify != build.autoNotifyEnabled {
            writes.append(.notification(BuildAutoNotifyRequest(detailID: build.betaDetailID ?? build.id, isEnabled: notify)))
        }
        if !add.isEmpty { writes.append(.add(BetaGroupMembershipRequest(buildID: build.id, groupIDs: add.map(\.id)))) }
        if !remove.isEmpty { writes.append(.remove(BetaGroupMembershipRequest(buildID: build.id, groupIDs: remove.map(\.id)))) }
        return writes
    }

    var addsExternalGroup: Bool { add.contains { !$0.isInternal } }
}

nonisolated enum DistributionStep: String, Sendable, Equatable {
    case notes, notification, addGroups, removeGroups, betaReview
}

nonisolated enum DistributionWrite: Sendable, Equatable {
    case notes(BetaNoteRequest)
    case notification(BuildAutoNotifyRequest)
    case add(BetaGroupMembershipRequest)
    case remove(BetaGroupMembershipRequest)
    case betaReview(BetaReviewSubmissionRequest)

    var isWellFormed: Bool {
        switch self {
        case .notes(let request): request.isWellFormed
        case .notification(let request): request.isWellFormed
        case .add(let request), .remove(let request): request.isWellFormed
        case .betaReview(let request): request.isWellFormed
        }
    }

    var step: DistributionStep {
        switch self {
        case .notes: .notes
        case .notification: .notification
        case .add: .addGroups
        case .remove: .removeGroups
        case .betaReview: .betaReview
        }
    }
}

/// How a distribution ended. Every case says which writes Apple accepted before it stopped; the build, when there is one, is
/// what Apple says afterwards, never what was asked for.
nonisolated enum DistributionOutcome: Sendable, Equatable {
    /// Apple accepted every write. `build` is read back; nil when that read failed.
    case accepted(completed: [DistributionStep], build: TestFlightBuild?)
    /// 403, or a key the user set to read only: nothing was sent for the step that failed.
    case notAllowed(message: String, completed: [DistributionStep])
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String, step: DistributionStep, completed: [DistributionStep])
    case rateLimited(completed: [DistributionStep])
    /// The request never left the Mac.
    case failed(message: String, completed: [DistributionStep])
    /// The request may have reached Apple. `build` is a fresh read; nil when that failed too.
    case uncertain(step: DistributionStep, completed: [DistributionStep], build: TestFlightBuild?)

    var completed: [DistributionStep] {
        switch self {
        case .accepted(let completed, _), .notAllowed(_, let completed), .refused(_, _, let completed), .rateLimited(let completed),
             .failed(_, let completed), .uncertain(_, let completed, _):
            completed
        }
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// What the card says when something did not go through; nil when every write was accepted.
    var message: String? {
        switch self {
        case .accepted:
            nil
        case .notAllowed(let message, let completed), .failed(let message, let completed):
            Self.joined(message, after: completed)
        case .refused(let message, _, let completed):
            Self.joined(message, after: completed)
        case .rateLimited(let completed):
            completed.isEmpty
                ? String(localized: "Apple’s hourly request limit is reached. Nothing was changed; try again later.")
                : Self.joined(String(localized: "Apple’s hourly request limit is reached. The rest was not sent; try again later."), after: completed)
        case .uncertain(_, let completed, let build):
            Self.joined(
                build == nil
                    ? String(localized: "Apple did not confirm the change, and the build could not be read back. Check it in App Store Connect before trying again.")
                    : String(localized: "Apple did not confirm the change. The card now shows the groups as Apple has them; look them over before trying again."),
                after: completed
            )
        }
    }

    /// “Already done: the test notes. …” in front of a message, when something went through before the stop.
    private static func joined(_ message: String, after completed: [DistributionStep]) -> String {
        guard !completed.isEmpty else { return message }
        let names = completed.map(Self.name).joined(separator: ", ")
        return String(localized: "Already done: \(names). \(message)", comment: "Before a message about a distribution that stopped half way; the first placeholder lists what Apple accepted, such as “the test notes, the new groups”")
    }

    private static func name(of step: DistributionStep) -> String {
        switch step {
        case .notes: String(localized: "the test notes", comment: "Part of a list of what a distribution already did")
        case .notification: String(localized: "the notification setting", comment: "Part of a list of what a distribution already did")
        case .addGroups: String(localized: "the new groups", comment: "Part of a list of what a distribution already did")
        case .removeGroups: String(localized: "the removed groups", comment: "Part of a list of what a distribution already did")
        case .betaReview: String(localized: "the beta review request", comment: "Part of a list of what a distribution already did")
        }
    }
}

nonisolated extension DistributionOutcome {
    static var forbiddenMessage: String {
        String(localized: "This key can’t distribute builds. It needs an Admin or App Manager key.")
    }

    static var readOnlyMessage: String {
        String(localized: "This account’s key is read-only: nothing was sent.")
    }
}
