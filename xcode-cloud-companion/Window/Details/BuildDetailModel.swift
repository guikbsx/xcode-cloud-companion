import Foundation

nonisolated struct InfoField: Identifiable, Equatable, Sendable {
    let title: String
    let value: String
    var help: String?

    var id: String { title }
}

nonisolated struct CommitInfo: Equatable, Sendable {
    let message: String?
    let author: String?
    let sha: String
    let shortSha: String
    let webURL: URL?
}

nonisolated struct ActionRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: BuildStatus
    let platform: String?
    let destination: String?
    let isRequired: Bool?
    let duration: String?
    let issueSummary: String?
}

/// Everything the build sheet shows, worked out from the cached build and its workflow. Unknown means hidden, never zero.
nonisolated struct BuildDetailModel: Equatable, Sendable {
    let id: String
    let numberText: String
    let status: BuildStatus
    let title: String
    /// The app's Store name, for the icon's initial while no icon is loaded.
    let appName: String?
    let reference: String?
    let shortSha: String?
    let frieze: [FriezeStep]
    let actions: [ActionRow]
    let info: [InfoField]
    let commit: CommitInfo?
    let issueCount: Int?
    let testFailureCount: Int?
    let appStoreConnectURL: URL

    init(run: CIBuildRun, product: CIProduct?, workflow: CIWorkflow?, actions: [CIBuildAction], teamID: String?, now: Date) {
        id = run.id
        numberText = run.number.map { "#\($0)" } ?? "#?"
        status = BuildStatus(run: run)
        appName = product?.displayName
        title = UsageFormat.dotted([appName, run.workflowName ?? workflow?.name].compactMap(\.self))
        reference = run.isPullRequestBuild == true
            ? run.pullRequestNumber.map { String(localized: "PR #\($0)", comment: "A pull request, in a build's line") }
            : run.sourceBranchOrTag
        shortSha = run.sourceCommit?.shortSha
        appStoreConnectURL = AppStoreConnectLinks.build(appID: product?.appID, buildRunID: run.id, teamID: teamID)

        let ordered = Self.ordered(actions)
        self.frieze = ordered.map { action in
            FriezeStep(id: action.id, name: Self.name(of: action), detail: Self.friezeDetail(of: action, now: now), status: BuildStatus(action: action))
        }
        let configured = workflow?.actions ?? []
        self.actions = ordered.map { action in
            let match = configured.first { $0.name != nil && $0.name == action.name }
            return ActionRow(
                id: action.id, name: Self.name(of: action), status: BuildStatus(action: action),
                platform: match?.platform.map(Self.label(of:)), destination: match?.destination,
                isRequired: action.isRequiredToPass ?? match?.isRequiredToPass,
                duration: Self.duration(of: action, now: now), issueSummary: Self.issueSummary(action.issueCounts)
            )
        }

        info = Self.info(run: run, workflow: workflow, now: now)
        commit = run.sourceCommit.flatMap { commit in
            commit.commitSha.map { sha in
                CommitInfo(
                    message: commit.message?.nilIfBlank, author: commit.authorName?.nilIfBlank, sha: sha, shortSha: String(sha.prefix(8)),
                    webURL: commit.webURL.flatMap { $0.scheme == "https" ? $0 : nil }
                )
            }
        }
        issueCount = run.issueCounts.map(\.total)
        testFailureCount = run.issueCounts?.testFailures
    }

    // MARK: - Actions

    private static func ordered(_ actions: [CIBuildAction]) -> [CIBuildAction] {
        func rank(_ type: CIActionType?) -> Int {
            switch type {
            case .build?: 0
            case .analyze?: 1
            case .test?: 2
            case .archive?: 3
            default: 4
            }
        }
        return actions.sorted { lhs, rhs in
            if let left = lhs.startedDate, let right = rhs.startedDate, left != right { return left < right }
            return (rank(lhs.actionType), lhs.name ?? "") < (rank(rhs.actionType), rhs.name ?? "")
        }
    }

    private static func name(of action: CIBuildAction) -> String {
        if let name = action.name?.nilIfBlank { return name }
        switch action.actionType {
        case .build?: return String(localized: "Build")
        case .analyze?: return String(localized: "Analyze")
        case .test?: return String(localized: "Test")
        case .archive?: return String(localized: "Archive")
        default: return "?"
        }
    }

    private static func label(of platform: CIPlatform) -> String {
        switch platform {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        case .visionOS: "visionOS"
        }
    }

    static func duration(of action: CIBuildAction, now: Date) -> String? {
        guard action.completionStatus != .skipped, let started = action.startedDate else { return nil }
        let seconds = max(0, (action.finishedDate ?? now).timeIntervalSince(started))
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    private static func issueSummary(_ counts: CIIssueCounts?) -> String? {
        guard let counts else { return nil }
        let failures = counts.testFailures ?? 0
        let errors = counts.errors ?? 0
        var parts: [String] = []
        if failures > 0 { parts.append(String(localized: "\(failures) test failures")) }
        if errors > 0 { parts.append(String(localized: "\(errors) errors")) }
        return parts.isEmpty ? nil : parts.formatted(.list(type: .and, width: .narrow))
    }

    private static func friezeDetail(of action: CIBuildAction, now: Date) -> String {
        switch BuildStatus(action: action) {
        case .skipped: return String(localized: "skipped")
        case .canceled: return String(localized: "canceled")
        default: break
        }
        let failures = (action.issueCounts?.testFailures ?? 0) > 0 ? action.issueCounts?.testFailures : nil
        return UsageFormat.dotted([
            duration(of: action, now: now) ?? (action.executionProgress == .pending ? String(localized: "waiting") : nil),
            failures.map { String(localized: "\($0) failures") },
        ].compactMap(\.self))
    }

    // MARK: - Info

    private static func info(run: CIBuildRun, workflow: CIWorkflow?, now: Date) -> [InfoField] {
        var fields: [InfoField] = []
        if let reason = run.startReason?.nilIfBlank {
            fields.append(InfoField(title: String(localized: "Start condition"), value: startReason(reason)))
        }
        if let started = run.startedDate {
            fields.append(InfoField(title: String(localized: "Started"), value: UsageFormat.moment(started)))
            if let created = run.createdDate, started >= created {
                fields.append(InfoField(title: String(localized: "Queued for"), value: spoken(started.timeIntervalSince(created))))
            }
            fields.append(InfoField(
                title: run.finishedDate == nil ? String(localized: "Elapsed") : String(localized: "Duration"),
                value: spoken(max(0, (run.finishedDate ?? now).timeIntervalSince(started)))
            ))
        }
        let note = String(localized: "Current workflow configuration: Apple doesn’t record the versions used by each build.")
        if let xcode = workflow?.xcodeVersionName?.nilIfBlank {
            fields.append(InfoField(title: "Xcode", value: xcode, help: note))
        }
        if let macOS = workflow?.macOSVersionName?.nilIfBlank {
            fields.append(InfoField(title: "macOS", value: macOS, help: note))
        }
        return fields
    }

    static func startReason(_ raw: String) -> String {
        switch raw {
        case "BRANCH_CHANGE": String(localized: "Branch change")
        case "GIT_REF_CHANGE": String(localized: "Git reference change")
        case "MANUAL": String(localized: "Manual start")
        case "MANUAL_REBUILD": String(localized: "Manual rebuild")
        case "PULL_REQUEST_OPEN": String(localized: "Pull request opened")
        case "PULL_REQUEST_UPDATE": String(localized: "Pull request updated")
        case "SCHEDULE": String(localized: "Schedule")
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

nonisolated extension BuildStatus {
    init(action: CIBuildAction) {
        switch (action.executionProgress, action.completionStatus) {
        case (.pending, _), (.running, _): self = .running
        case (_, .succeeded?): self = .succeeded
        case (_, .failed?): self = .failed
        case (_, .errored?): self = .errored
        case (_, .canceled?): self = .canceled
        case (_, .skipped?): self = .skipped
        default: self = .finished
        }
    }
}

nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
