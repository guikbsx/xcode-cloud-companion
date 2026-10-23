import Foundation

/// How the expiration of a build ended. The build, when there is one, is what Apple says afterwards.
nonisolated enum ExpirationOutcome: Sendable, Equatable {
    /// Apple accepted, or the build read back after an unclear answer is expired. `build` is read back; nil when that failed.
    case expired(build: TestFlightBuild?)
    /// 403, or a key the user set to read only: nothing was sent.
    case notAllowed(message: String)
    /// 409 and 422: Apple understood and refused; its words are shown as they are.
    case refused(message: String)
    case rateLimited
    /// The request never left the Mac.
    case failed(message: String)
    /// The request may have reached Apple and the build read back is not expired; nil when it could not be read.
    case uncertain(build: TestFlightBuild?)

    var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }

    /// What the card says when the build was not expired; nil when it was.
    var message: String? {
        switch self {
        case .expired:
            nil
        case .notAllowed(let message), .refused(let message), .failed(let message):
            message
        case .rateLimited:
            String(localized: "Apple’s hourly request limit is reached. The build was not expired; try again later.")
        case .uncertain(let build):
            build == nil
                ? String(localized: "Apple did not confirm the expiration, and the build could not be read back. Check it in App Store Connect before trying again.")
                : String(localized: "Apple did not confirm the expiration. The card now shows the build as Apple has it; look it over before trying again.")
        }
    }

    static var forbiddenMessage: String {
        String(localized: "This key can’t expire builds. It needs an Admin or App Manager key.")
    }
}

/// What one “Give Access” and the expiration of the previous build that went with it came to. The expiration is only tried when
/// Apple accepted the groups, so `expiration` is nil in every other case.
nonisolated struct DistributionResult: Sendable, Equatable {
    var distribution: DistributionOutcome
    var expiration: ExpirationOutcome?
}

/// The build a new one replaces: the most recent older build of the app that is still in testing for at least one group.
nonisolated struct PreviousBuild: Sendable, Equatable {
    var build: TestFlightBuild
    /// The groups it is still in testing for.
    var groupCount: Int

    static func find(before current: TestFlightBuild, among builds: [TestFlightBuild], groups: [BetaGroup], now: Date) -> PreviousBuild? {
        guard let uploaded = current.uploadedDate else { return nil }
        let older = builds
            .filter { $0.id != current.id && ($0.uploadedDate ?? .distantFuture) < uploaded }
            .sorted { ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast) }
        for build in older where TestFlightExpiration.canBeExpired(build, at: now) {
            let members = TestFlightDistributionPlan.members(of: build, in: groups)
            let testing = groups.filter { group in
                members.contains(group.id) && (group.isInternal ? build.internalState : build.externalState) == .testing
            }
            if !testing.isEmpty { return PreviousBuild(build: build, groupCount: testing.count) }
        }
        return nil
    }
}

nonisolated enum TestFlightExpiration {
    /// A processed build that is not expired yet.
    static func canBeExpired(_ build: TestFlightBuild, at now: Date) -> Bool {
        guard build.processing == .valid else { return false }
        switch build.status(at: now) {
        case .processing, .processingFailed, .expired: return false
        default: return true
        }
    }

    /// Whether the menu of the build offers “Expire this build…”.
    static func isOffered(for build: TestFlightBuild, canWrite: Bool, now: Date) -> Bool {
        canWrite && canBeExpired(build, at: now)
    }

    private static func inBetaReview(_ build: TestFlightBuild) -> Bool {
        [.waitingForReview, .inReview].contains(build.externalState) || build.review == .waiting || build.review == .inReview
    }

    /// The groups that lose the build, with the testers they hold when every count is known.
    static func losingGroups(of build: TestFlightBuild, in groups: [BetaGroup]) -> [BetaGroup] {
        let members = TestFlightDistributionPlan.members(of: build, in: groups)
        return groups.filter { members.contains($0.id) }
    }

    static func alertTitle(appName: String?, label: String) -> String {
        let name = [appName, label].compactMap(\.self).joined(separator: " ")
        return String(localized: "Expire \(name)?", comment: "Confirmation title: the placeholder is an app and a build such as “Brioche 1.4 (412)”")
    }

    static func alertMessage(for build: TestFlightBuild, groups: [BetaGroup]) -> String {
        let losing = losingGroups(of: build, in: groups)
        var sentences: [String] = []
        if losing.isEmpty {
            sentences.append(String(localized: "No group has this build."))
        } else {
            let names = losing.map(\.name).formatted(.list(type: .and))
            let counts = losing.compactMap(\.testerCount)
            if counts.count == losing.count {
                let total = counts.reduce(0, +)
                sentences.append(
                    total == 1
                        ? String(localized: "The tester of \(names) will no longer be able to install it.", comment: "Expire confirmation: the placeholder lists the groups that lose the build")
                        : String(localized: "The \(total) testers of \(names) will no longer be able to install it.", comment: "Expire confirmation: the first placeholder is a number of testers, the second lists the groups that lose the build")
                )
            } else {
                sentences.append(String(localized: "The testers of \(names) will no longer be able to install it.", comment: "Expire confirmation: the placeholder lists the groups that lose the build"))
            }
        }
        if inBetaReview(build) {
            sentences.append(String(localized: "The beta review in progress stops."))
        }
        sentences.append(String(localized: "An expiration can’t be undone."))
        return sentences.joined(separator: " ")
    }

    static var alertConfirm: String { String(localized: "Expire", comment: "Button that expires a TestFlight build for good") }
    static var alertCancel: String { String(localized: "Cancel") }
    static var copyBuildNumber: String { String(localized: "Copy Build Number", comment: "Menu item of the TestFlight card") }
    static var openInAppStoreConnect: String { String(localized: "Open in App Store Connect", comment: "Menu item of the TestFlight card") }
    static var expireItem: String { String(localized: "Expire This Build", comment: "Button of the TestFlight card, beside Give Access: makes the build unavailable for testing for good, after a confirmation") }
    static var moreActions: String { String(localized: "More Actions", comment: "Accessibility label of the menu on the TestFlight card") }
    static var expiring: String { String(localized: "Expiring…", comment: "State of a TestFlight build while Apple expires it") }

    static func previousToggle(label: String) -> String {
        String(localized: "Expire \(label)", comment: "Checkbox of the confirmation that gives a build to groups: the placeholder is the previous build such as “1.4 (411)”")
    }

    static func previousDetail(groupCount: Int) -> String {
        String(localized: "Still in testing for \(groupCount) groups. This can’t be undone.", comment: "Under the checkbox that expires the previous build; the placeholder is a number of groups")
    }

    static func previousFailed(label: String) -> String {
        String(localized: "\(label) was not expired.", comment: "After a distribution: the previous build could not be expired; the placeholder is a build such as “1.4 (411)”")
    }

    static var groupsUpdated: String {
        String(localized: "The groups of the new build were updated.")
    }
}
