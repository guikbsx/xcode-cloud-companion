import Foundation

/// The words of the card that gives a build to groups, and of its confirmation.
nonisolated enum TestFlightDistributionText {
    static func testers(_ count: Int) -> String {
        String(localized: "\(count) testers", comment: "Beside a TestFlight group: how many testers it has; the placeholder is a number")
    }

    static var receivesEveryBuild: String {
        String(localized: "Receives every build", comment: "Under an internal TestFlight group that gets every build by itself")
    }

    static var betaReviewFirst: String {
        String(localized: "Apple beta review first", comment: "Under an external TestFlight group: its testers get a build after Apple's beta review")
    }

    /// What the foot of the card says will change; nothing is sent before the button. Nil while nothing would.
    static func summary(_ plan: TestFlightDistributionPlan) -> String? {
        let adds = plan.toAdd.count
        let removes = plan.toRemove.count
        let toAdd = String(localized: "\(adds) groups to add", comment: "Foot of the TestFlight card: how many groups would be given the build; the placeholder is a number")
        let toRemove = String(localized: "\(removes) to remove", comment: "Foot of the TestFlight card: how many groups would lose the build; the placeholder is a number")
        switch (adds, removes) {
        case (0, 0): return nil
        case (_, 0): return toAdd
        case (0, _): return toRemove
        default: return UsageFormat.dotted([toAdd, toRemove])
        }
    }

    static func sheetTitle(label: String, plan: TestFlightDistributionPlan) -> String {
        let adds = plan.toAdd.count
        let removes = plan.toRemove.count
        switch (adds, removes) {
        case (_, 0): return String(localized: "Give \(label) to \(adds) groups?", comment: "Confirmation title: the first placeholder is a build such as “1.4 (412)”, the second a number of groups")
        case (0, _): return String(localized: "Take \(label) from \(removes) groups?", comment: "Confirmation title: the first placeholder is a build such as “1.4 (412)”, the second a number of groups")
        default: return String(localized: "Change the groups of \(label)?", comment: "Confirmation title: the placeholder is a build such as “1.4 (412)”")
        }
    }

    static func confirmButton(plan: TestFlightDistributionPlan) -> String {
        plan.toAdd.isEmpty
            ? String(localized: "Remove Access", comment: "Button that takes a TestFlight build from groups")
            : String(localized: "Give Access", comment: "Button that gives a TestFlight build to groups")
    }

    static func badge(_ tone: TestFlightDistributionCardModel.Badge.Tone) -> String {
        switch tone {
        case .available: String(localized: "Available", comment: "State of a TestFlight build that testers can install")
        case .awaitingReview: String(localized: "Awaiting review", comment: "State of a TestFlight group's access: the beta review has not started")
        case .inReview: String(localized: "In review", comment: "State of a TestFlight group's access: the beta review is looking at the build")
        case .rejected: String(localized: "Rejected", comment: "State of a TestFlight group's access: the beta review turned the build down")
        }
    }
}

/// The card that gives a build to groups: its header, and the groups in two blocks with the box each one is checked by.
nonisolated struct TestFlightDistributionCardModel: Sendable, Equatable {
    /// What the card can do for the build as it stands.
    enum Mode: Sendable, Equatable {
        case open
        /// Apple still processes the build: the groups show, disabled.
        case processing
        case processingFailed
        /// Apple waits for the answer about encryption: no groups, a way to App Store Connect.
        case missingCompliance
        /// A build that stopped working: the groups show, disabled.
        case expired
        /// The account's key is read-only: no groups, a way to the Settings.
        case readOnlyKey
    }

    struct Badge: Sendable, Equatable {
        enum Tone: Sendable, Equatable {
            case available, awaitingReview, inReview, rejected
        }

        let tone: Tone
        var text: String { TestFlightDistributionText.badge(tone) }
    }

    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let isInternal: Bool
        let receivesEveryBuild: Bool
        /// “4 testers”; nil while the count is unknown.
        let testers: String?
        /// The member's access as Apple has it; nil for a group that does not have the build.
        let badge: Badge?
        let isMember: Bool

        /// The line under the name: why the group is locked, or what an external group goes through.
        var note: String? {
            if receivesEveryBuild { return TestFlightDistributionText.receivesEveryBuild }
            return isInternal ? nil : TestFlightDistributionText.betaReviewFirst
        }
    }

    let label: String
    let statusText: String
    let mode: Mode
    let rows: [Row]
    /// Whether the card offers “Expire This Build”.
    let canExpire: Bool

    var internalRows: [Row] { rows.filter(\.isInternal) }
    var externalRows: [Row] { rows.filter { !$0.isInternal } }

    /// Whether the boxes can be checked.
    var isEditable: Bool { mode == .open }

    /// The sentence that stands in for the groups, or above them when they are disabled; nil when the card is open.
    var message: String? {
        switch mode {
        case .open: nil
        case .processing: String(localized: "Apple is still processing the build. The groups open when the processing ends.")
        case .processingFailed: String(localized: "Apple could not process this build, so it can’t be distributed.")
        case .missingCompliance: String(localized: "Apple is waiting for your answer about encryption before any distribution.")
        case .expired: String(localized: "An expired build can’t be distributed.")
        case .readOnlyKey: String(localized: "This account’s key is read-only.")
        }
    }

    /// Whether the groups are listed at all.
    var showsGroups: Bool {
        switch mode {
        case .open, .processing, .expired: true
        case .processingFailed, .missingCompliance, .readOnlyKey: false
        }
    }

    static func make(
        build: TestFlightBuild, groups: [BetaGroup], canWrite: Bool, now: Date, expiredSeenAt: Date? = nil, locale: Locale = .autoupdatingCurrent
    ) -> TestFlightDistributionCardModel {
        let status = build.status(at: now)
        let mode: Mode = if status == .expired {
            .expired
        } else if status == .processing {
            .processing
        } else if status == .processingFailed {
            .processingFailed
        } else if build.needsExportCompliance {
            .missingCompliance
        } else if !canWrite {
            .readOnlyKey
        } else {
            .open
        }
        let members = TestFlightDistributionPlan.members(of: build, in: groups)
        let rows = groups.map { group in
            Row(
                id: group.id, name: group.name, isInternal: group.isInternal, receivesEveryBuild: group.receivesEveryBuild,
                testers: group.testerCount.map(TestFlightDistributionText.testers), badge: members.contains(group.id) ? badge(for: group, of: build) : nil,
                isMember: members.contains(group.id)
            )
        }
        let statusText = build.needsExportCompliance && status != .expired
            ? String(localized: "To complete", comment: "State of a TestFlight build whose export compliance answer is missing")
            : TestFlightText.statusLine(of: build, now: now, expiredSeenAt: expiredSeenAt, locale: locale)
        return TestFlightDistributionCardModel(label: build.label, statusText: statusText, mode: mode, rows: rows, canExpire: TestFlightExpiration.isOffered(for: build, canWrite: canWrite, now: now))
    }

    /// What Apple says of a member group, from the state of the build for its kind of testers.
    private static func badge(for group: BetaGroup, of build: TestFlightBuild) -> Badge? {
        let state = group.isInternal ? build.internalState : build.externalState
        switch state {
        case .testing: return Badge(tone: .available)
        case .waitingForReview where !group.isInternal: return Badge(tone: .awaitingReview)
        case .inReview where !group.isInternal: return Badge(tone: .inReview)
        case .rejected where !group.isInternal: return Badge(tone: .rejected)
        default: return nil
        }
    }

    /// The rows of the card's skeleton.
    static let placeholder = TestFlightDistributionCardModel(
        label: "1.4 (412)", statusText: "Ready", mode: .open,
        rows: BetaGroup.placeholders.map {
            Row(
                id: $0.id, name: $0.name, isInternal: $0.isInternal, receivesEveryBuild: $0.receivesEveryBuild,
                testers: $0.testerCount.map(TestFlightDistributionText.testers), badge: nil, isMember: $0.receivesEveryBuild
            )
        },
        canExpire: false
    )
}

/// The confirmation: the build and the groups it concerns, one line each.
nonisolated struct TestFlightDistributionSheetModel: Sendable, Equatable {
    struct Line: Identifiable, Sendable, Equatable {
        enum Chip: Sendable, Equatable {
            case rightAway, betaReview, removed
        }

        let id: String
        /// “QA · 2 testers”.
        let title: String
        let detail: String
        let chip: Chip
    }

    let title: String
    let lines: [Line]
    let confirmButton: String

    static func make(label: String, plan: TestFlightDistributionPlan) -> TestFlightDistributionSheetModel {
        func title(_ group: BetaGroup) -> String {
            group.testerCount.map { UsageFormat.dotted([group.name, TestFlightDistributionText.testers($0)]) } ?? group.name
        }
        let added = plan.toAdd.map { group in
            Line(
                id: group.id, title: title(group),
                detail: group.isInternal
                    ? String(localized: "available right away", comment: "Under a TestFlight group in the confirmation: its testers get the build at once")
                    : String(localized: "Apple beta review first", comment: "Under a TestFlight group in the confirmation: its testers get the build after Apple's beta review"),
                chip: group.isInternal ? .rightAway : .betaReview
            )
        }
        let removed = plan.toRemove.map { group in
            Line(
                id: group.id, title: title(group),
                detail: String(localized: "loses access to the build", comment: "Under a TestFlight group in the confirmation: its testers can no longer install the build"),
                chip: .removed
            )
        }
        return TestFlightDistributionSheetModel(
            title: TestFlightDistributionText.sheetTitle(label: label, plan: plan), lines: added + removed,
            confirmButton: TestFlightDistributionText.confirmButton(plan: plan)
        )
    }
}

nonisolated extension TestFlightDistributionSheetModel.Line.Chip {
    var text: String {
        switch self {
        case .rightAway: String(localized: "Right away", comment: "Chip of a TestFlight group in the confirmation: its testers get the build at once")
        case .betaReview: String(localized: "Beta review", comment: "Chip of an external TestFlight group in the confirmation: Apple reviews the build first")
        case .removed: String(localized: "Removed", comment: "Chip of a TestFlight group in the confirmation: it loses the build")
        }
    }
}

/// The languages the test notes can be written in: those Apple already holds for the build, or a first pair to start from.
nonisolated enum TestFlightNoteLocales {
    static let starters = ["en-US", "fr-FR"]

    static func choices(existing: [BetaBuildNote]) -> [String] {
        let known = existing.map(\.locale)
        return known.isEmpty ? starters : known
    }

    /// The language the interface runs in if the build has notes in it, else the first one.
    static func initial(choices: [String], preferred: [String] = Locale.preferredLanguages) -> String? {
        for language in preferred {
            let code = language.split(separator: "-").first.map(String.init) ?? language
            if let match = choices.first(where: { $0.hasPrefix(code) }) { return match }
        }
        return choices.first
    }

    static func name(_ locale: String, in display: Locale = .autoupdatingCurrent) -> String {
        (display.localizedString(forIdentifier: locale) ?? locale).localizedCapitalized
    }
}
