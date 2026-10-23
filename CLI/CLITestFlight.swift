import Foundation

/// What the shared folder says about a build's TestFlight build: the build itself, and the groups of its app. The app writes
/// both next to the account's other caches; the command never asks Apple.
nonisolated struct TestFlightKnowledge: Equatable, Sendable {
    var build: TestFlightBuild?
    /// The App Store Connect app, from the reading that holds the build or else from the Xcode Cloud product.
    var appID: String?
    /// Nil until the app read them.
    var groups: [BetaGroup]?
    /// Nil when the app never listed the TestFlight builds of the Xcode Cloud build.
    var listedBuildIDs: [String]?

    /// Whether the running app could add something by reading: the list of builds, the build itself or the groups.
    func isIncomplete(for run: CIBuildRun) -> Bool {
        guard run.executionProgress == .complete else { return false }
        if listedBuildIDs == nil { return true }
        if let ids = listedBuildIDs, !ids.isEmpty, build == nil { return false }
        return build != nil && groups == nil
    }
}

nonisolated enum CLITestFlightFiles {
    static func knowledge(of run: CIBuildRun, appID: String?, in directory: URL) async -> TestFlightKnowledge {
        let extras = await BuildExtrasCache(directory: directory.appending(path: "BuildDetails")).load(runID: run.id)
        let listed = extras?.betaBuilds?.map(\.id)
        let wanted = Set(listed ?? [])
        let file = await TestFlightCache(fileURL: directory.appending(path: "TestFlight.json")).load()
        let readings = file.map { Array($0.readings.values) } ?? []
        let found = readings
            .flatMap { reading in reading.builds.filter { wanted.contains($0.id) }.map { (build: $0, appID: reading.appID) } }
            .max { ($0.build.uploadedDate ?? .distantPast) < ($1.build.uploadedDate ?? .distantPast) }
        let resolvedAppID = found?.appID ?? appID
        let groupsFile = await BetaGroupsCache(fileURL: directory.appending(path: "TestFlightGroups.json")).load()
        return TestFlightKnowledge(
            build: found?.build, appID: resolvedAppID, groups: resolvedAppID.flatMap { groupsFile?.readings[$0]?.groups }, listedBuildIDs: listed
        )
    }
}

nonisolated enum CLITestFlightWords {
    static func status(_ status: TestFlightStatus) -> String {
        switch status {
        case .processing: "processing"
        case .processingFailed: "processingFailed"
        case .waitingForReview: "waitingForReview"
        case .inReview: "inReview"
        case .rejected: "rejected"
        case .available: "available"
        case .ready: "ready"
        case .expired: "expired"
        case .unknown: "unknown"
        }
    }

    /// “QA, Beta and Friends”.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}

nonisolated enum CLITestFlightGroups {
    /// One group by its identifier, or by its name whatever the case; a name two groups share is ambiguous.
    static func resolve(_ reference: String, in groups: [BetaGroup]) throws(CLIFailure) -> BetaGroup {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let exact = groups.first(where: { $0.id == wanted }) {
            return exact
        }
        let matches = groups.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw CLIFailure(code: .notFound, message: "No group of this app is named '\(wanted)'.", suggestions: groups.map(known))
        default:
            throw CLIFailure(
                code: .ambiguous, message: "Several groups of this app are named '\(wanted)'.",
                suggestions: matches.map { "Use its id: \($0.id) (\($0.name), \($0.isInternal ? "internal" : "external"))" }
            )
        }
    }

    static func known(_ group: BetaGroup) -> String {
        "Known group: \(group.name) (\(group.isInternal ? "internal" : "external")\(group.receivesEveryBuild ? ", receives every build" : ""))"
    }
}

/// The words of the question asked at a terminal.
nonisolated enum CLITestFlightQuestion {
    static func give(app: String, label: String, add: [BetaGroup], remove: [BetaGroup]) -> String {
        let added = add.map { $0.isInternal ? $0.name : "\($0.name) (beta review first)" }
        let removed = remove.map(\.name)
        switch (added.isEmpty, removed.isEmpty) {
        case (false, true): return "Give \(app) \(label) to \(CLITestFlightWords.list(added))? [y/N]"
        case (true, false): return "Take \(app) \(label) from \(CLITestFlightWords.list(removed))? [y/N]"
        default: return "Give \(app) \(label) to \(CLITestFlightWords.list(added)) and take it from \(CLITestFlightWords.list(removed))? [y/N]"
        }
    }

    static func expire(app: String, label: String, build: TestFlightBuild, groups: [BetaGroup]?) -> String {
        var sentences = ["Expire \(app) \(label)?"]
        if let groups {
            let members = build.memberGroupIDs(in: groups)
            let losing = groups.filter { members.contains($0.id) }
            if losing.isEmpty {
                sentences.append("No group has this build.")
            } else {
                let names = CLITestFlightWords.list(losing.map(\.name))
                let counts = losing.compactMap(\.testerCount)
                if counts.count == losing.count {
                    let total = counts.reduce(0, +)
                    sentences.append(total == 1 ? "The tester of \(names) will no longer be able to install it." : "The \(total) testers of \(names) will no longer be able to install it.")
                } else {
                    sentences.append("The testers of \(names) will no longer be able to install it.")
                }
            }
        } else {
            sentences.append("Its testers will no longer be able to install it.")
        }
        if [.waitingForReview, .inReview].contains(build.externalState) || build.review == .waiting || build.review == .inReview {
            sentences.append("The beta review in progress stops.")
        }
        sentences.append("An expiration can't be undone. [y/N]")
        return sentences.joined(separator: " ")
    }
}

/// The build a TestFlight command is about, as the cache and the shared files know it, before the person is asked.
nonisolated struct TestFlightTarget: Equatable, Sendable {
    var buildRunID: String
    /// `App#42`.
    var reference: String?
    var app: String
    /// “1.4 (412)”.
    var label: String
    var testFlightBuildID: String
    var accountID: String
    var accountName: String
    var showsAccount: Bool
    var lastSuccessfulSync: Date?
    var directory: URL
    var runID: String
    var appID: String?
}

nonisolated struct TestFlightGivePlan: Equatable, Sendable {
    var request: IPCTestFlightGiveRequest
    var target: TestFlightTarget
    var question: String
}

nonisolated struct TestFlightExpirePlan: Equatable, Sendable {
    var request: IPCTestFlightExpireRequest
    var target: TestFlightTarget
    var question: String
    var build: TestFlightBuild
}

typealias TestFlightFound = (scope: CLIAccountScope, snapshot: BuildSnapshot, run: CIBuildRun, product: CIProduct?, knowledge: TestFlightKnowledge)

nonisolated extension CLIQueryRunner {
    /// The TestFlight build of an Xcode Cloud build, with the groups of its app. What the shared folder lacks, the running app is
    /// asked to read, once, unless `fetch` is false; a write starts the app for it, a reading does not.
    func testFlightKnowledge(
        reference: String, scope: CLIAccountScope, snapshot: BuildSnapshot, startingApp: Bool, fetch: Bool
    ) async throws(CLIFailure) -> TestFlightFound {
        let run = try CLIReference.run(reference, in: snapshot)
        let product = snapshot.products.first { $0.id == run.productID }
        var knowledge = await CLITestFlightFiles.knowledge(of: run, appID: product?.appID, in: scope.directory)
        if fetch, knowledge.isIncomplete(for: run) {
            let link = CLIAppLink(environment: environment, accountID: scope.account.id)
            if await link.testFlightLoad(buildRunID: run.id, startingApp: startingApp) {
                knowledge = await CLITestFlightFiles.knowledge(of: run, appID: product?.appID, in: scope.directory)
            }
        }
        return (scope, snapshot, run, product, knowledge)
    }

    private func testFlightFoundForWriting(reference: String) async throws(CLIFailure) -> TestFlightFound {
        let scope = try await CLIAccountScope.resolve(account, in: environment.directory)
        let snapshot = try await CLIData.load(from: scope.directory, includingUsage: false).snapshot
        return try await testFlightKnowledge(reference: reference, scope: scope, snapshot: snapshot, startingApp: true, fetch: true)
    }

    static func testFlightHint(for run: CIBuildRun, knowledge: TestFlightKnowledge) -> String? {
        guard run.executionProgress == .complete else { return "This build is still running: it has no TestFlight build yet." }
        guard let listed = knowledge.listedBuildIDs else {
            return "Cumulus has not listed this build's TestFlight builds: start Cumulus, then ask again."
        }
        guard !listed.isEmpty else {
            return "This build has no TestFlight build: its workflow does not archive for TestFlight, or the archive did not succeed."
        }
        guard knowledge.build != nil else {
            return "Cumulus has not read this TestFlight build yet: it reads an app's latest builds after a sync. Run 'cumulus refresh --wait', then ask again."
        }
        guard knowledge.groups != nil else {
            return "Cumulus has not read the groups of this app: start Cumulus and ask again. A key that cannot read TestFlight never will."
        }
        return nil
    }

    static func testFlightOutput(
        run: CIBuildRun, product: CIProduct?, reference: String?, knowledge: TestFlightKnowledge, now: Date
    ) -> TestFlightOutput {
        let members = knowledge.build.flatMap { build in knowledge.groups.map { build.memberGroupIDs(in: $0) } } ?? []
        return TestFlightOutput(
            buildRunID: run.id, reference: reference, app: product?.name ?? run.productID,
            build: knowledge.build.map { testFlightBuildOutput($0, now: now) },
            groups: knowledge.groups?.map { group in
                TestFlightOutput.Group(
                    id: group.id, name: group.name, kind: group.isInternal ? "internal" : "external", receivesEveryBuild: group.receivesEveryBuild,
                    testerCount: group.testerCount, hasBuild: members.contains(group.id)
                )
            },
            hint: testFlightHint(for: run, knowledge: knowledge)
        )
    }

    static func testFlightBuildOutput(_ build: TestFlightBuild, now: Date) -> TestFlightOutput.Build {
        TestFlightOutput.Build(
            id: build.id, label: build.label, version: build.marketingVersion, buildNumber: build.buildNumber, platform: build.platform,
            status: CLITestFlightWords.status(build.status(at: now)), processingState: build.processing.rawValue,
            internalState: build.internalState.rawValue, externalState: build.externalState.rawValue, betaReview: build.review?.rawValue,
            uploadedDate: build.uploadedDate, expirationDate: build.expirationDate, daysLeft: build.daysLeft(at: now),
            notifiesTesters: build.autoNotifyEnabled, needsExportCompliance: build.needsExportCompliance
        )
    }

    private func testFlightTarget(_ found: TestFlightFound) throws(CLIFailure) -> (TestFlightTarget, TestFlightBuild) {
        guard let build = found.knowledge.build else {
            throw CLIFailure(
                code: .notFound, message: "Cumulus knows no TestFlight build for this build.",
                suggestions: [Self.testFlightHint(for: found.run, knowledge: found.knowledge)].compactMap(\.self)
            )
        }
        let name = found.product?.name ?? found.run.productID
        return (
            TestFlightTarget(
                buildRunID: found.run.id, reference: found.run.number.map { "\(name)#\($0)" }, app: found.product?.displayName ?? name, label: build.label,
                testFlightBuildID: build.id, accountID: found.scope.account.id, accountName: found.scope.account.name,
                showsAccount: found.scope.hasSiblings, lastSuccessfulSync: found.snapshot.lastSuccessfulSync, directory: found.scope.directory,
                runID: found.run.id, appID: found.knowledge.appID
            ),
            build
        )
    }

    /// Everything `cumulus testflight give` needs before it asks the person, then the app: the build and the groups, by name.
    func prepareTestFlightGive(_ command: TestFlightGiveCommand) async throws(CLIFailure) -> TestFlightGivePlan {
        let found = try await testFlightFoundForWriting(reference: command.build)
        let (target, _) = try testFlightTarget(found)
        guard let groups = found.knowledge.groups else {
            throw CLIFailure(
                code: .notFound, message: "Cumulus has not read the groups of this app.",
                suggestions: ["Start Cumulus and try again. A key that cannot read TestFlight cannot change it either."]
            )
        }
        var add: [BetaGroup] = []
        for name in command.add {
            add.append(try CLITestFlightGroups.resolve(name, in: groups))
        }
        var remove: [BetaGroup] = []
        for name in command.remove {
            remove.append(try CLITestFlightGroups.resolve(name, in: groups))
        }
        if let fixed = (add + remove).first(where: \.receivesEveryBuild) {
            throw CLIFailure(
                code: .usage, message: "'\(fixed.name)' receives every build by itself: a build is neither given to it nor taken from it.",
                suggestions: groups.filter { !$0.receivesEveryBuild }.map(CLITestFlightGroups.known)
            )
        }
        guard Set((add + remove).map(\.id)).count == add.count + remove.count else {
            throw CLIFailure(code: .usage, message: "A group is named twice: give the build to a group or take it from it, not both.")
        }
        return TestFlightGivePlan(
            request: IPCTestFlightGiveRequest(
                testFlightBuildID: target.testFlightBuildID, addGroupIDs: add.map(\.id), removeGroupIDs: remove.map(\.id), notes: command.notes,
                locale: command.locale, notify: command.notify, accountID: target.accountID
            ),
            target: target, question: CLITestFlightQuestion.give(app: target.app, label: target.label, add: add, remove: remove)
        )
    }

    func testFlightGive(_ plan: TestFlightGivePlan) async throws(CLIFailure) -> CLIResponse {
        let (result, appLaunched) = try await CLIAppLink(environment: environment, accountID: plan.target.accountID).testFlightGive(plan.request)
        let build = await freshBuild(plan.target, result: result)
        let output = TestFlightChangeOutput(
            action: "give", buildRunID: plan.target.buildRunID, reference: plan.target.reference, app: plan.target.app,
            added: result.addedGroups ?? [], removed: result.removedGroups ?? [], unchanged: result.unchangedGroups ?? [], steps: result.steps ?? [],
            notifiesTesters: build?.notifiesTesters, changed: result.written ?? false, build: build, appLaunched: appLaunched, message: result.message
        )
        return CLIResponse(report: .testFlightChange(output), meta: changeMeta(plan.target))
    }

    func prepareTestFlightExpire(_ command: TestFlightExpireCommand) async throws(CLIFailure) -> TestFlightExpirePlan {
        let found = try await testFlightFoundForWriting(reference: command.build)
        let (target, build) = try testFlightTarget(found)
        return TestFlightExpirePlan(
            request: IPCTestFlightExpireRequest(testFlightBuildID: target.testFlightBuildID, accountID: target.accountID), target: target,
            question: CLITestFlightQuestion.expire(app: target.app, label: target.label, build: build, groups: found.knowledge.groups), build: build
        )
    }

    func testFlightExpire(_ plan: TestFlightExpirePlan) async throws(CLIFailure) -> CLIResponse {
        let (result, appLaunched) = try await CLIAppLink(environment: environment, accountID: plan.target.accountID).testFlightExpire(plan.request)
        let build = await freshBuild(plan.target, result: result)
        let output = TestFlightChangeOutput(
            action: "expire", buildRunID: plan.target.buildRunID, reference: plan.target.reference, app: plan.target.app,
            changed: result.written ?? false, build: build, appLaunched: appLaunched, message: result.message
        )
        return CLIResponse(report: .testFlightChange(output), meta: changeMeta(plan.target))
    }

    /// The build as the app read it back after the write; nothing when it could not be read, rather than a state that is stale.
    private func freshBuild(_ target: TestFlightTarget, result: IPCResult) async -> TestFlightOutput.Build? {
        guard result.refreshed == true else { return nil }
        let file = await TestFlightCache(fileURL: target.directory.appending(path: "TestFlight.json")).load()
        let build = file?.readings.values.lazy.compactMap { $0.build(id: target.testFlightBuildID) }.first
        return build.map { Self.testFlightBuildOutput($0, now: environment.now()) }
    }

    private func changeMeta(_ target: TestFlightTarget) -> CLIMeta {
        CLIMeta(
            lastSuccessfulSync: target.lastSuccessfulSync, generatedAt: environment.now(), cliVersion: environment.version, appRunning: true,
            account: target.accountName, showsAccount: target.showsAccount
        )
    }
}
