import Foundation

/// How many TestFlight writes agents may make in an hour, per account: giving a build to groups and expiring it each count one.
/// It does not share the hour of `AgentLaunchGate`: a build started and a build given to testers spend different things.
nonisolated enum AgentTestFlightGate {
    static let cap = 10
    static let window: TimeInterval = 3600

    static func allows(_ writes: [Date], now: Date) -> (allowed: Bool, nextAt: Date?) {
        AgentLaunchGate.allows(writes, now: now, cap: cap, window: window)
    }
}

/// Gives a TestFlight build to groups, takes it from others, or expires it, when the command or an MCP tool asks over the
/// socket: the window's own `TestFlightDistributor`, behind the key's access and the cap. No request is repeated;
/// a 403 puts the key in read-only mode as it does in the window. The command reads the shared files; this is where it
/// writes, and where what the files may lack gets read.
@MainActor
final class AgentTestFlightService {
    private struct Refusal: Error {
        var result: IPCResult
    }

    private let accounts: AccountsModel
    private let preferences: NotificationPreferences
    private let notify: ([LocalNotification]) async -> Void
    private let now: () -> Date
    private var writes: [String: [Date]] = [:]

    init(accounts: AccountsModel, preferences: NotificationPreferences, notify: @escaping ([LocalNotification]) async -> Void, now: @escaping () -> Date = { Date() }) {
        self.accounts = accounts
        self.preferences = preferences
        self.notify = notify
        self.now = now
    }

    // MARK: - Reading

    /// Reads, for the command, what the shared folder lacks to talk about a build's TestFlight build: the list of its TestFlight
    /// builds and the groups of its app. Only reads, and only for an account Cumulus follows.
    func load(buildRunID: String) async -> IPCResult {
        guard let session = await accounts.owner(ofBuild: buildRunID) else { return IPCResult(loaded: false) }
        await session.buildStore.loadCacheIfNeeded()
        guard let run = session.buildStore.snapshot.runs.first(where: { $0.id == buildRunID }), run.executionProgress == .complete else {
            return IPCResult(loaded: false)
        }
        await session.extrasStore.loadBetaBuilds(for: run)
        await session.testFlight.loadCache()
        let appID = session.buildStore.snapshot.products.first { $0.id == run.productID }?.appID
        if let appID {
            await session.testFlightGroups.load(appID: appID)
        }
        return IPCResult(loaded: true)
    }

    // MARK: - Writing

    func give(_ request: IPCTestFlightGiveRequest) async -> IPCResult {
        do throws(Refusal) {
            let session = try await authorizedSession(accountID: request.accountID)
            let (build, groups, productID) = try await buildAndGroups(session, buildID: request.testFlightBuildID)
            let mode = TestFlightDistributionCardModel.make(build: build, groups: groups, canWrite: true, now: now()).mode
            if mode != .open {
                throw refusal(IPCTestFlightReason.buildNotReady, message: Self.message(for: mode))
            }

            let add = try Self.groups(request.addGroupIDs, in: groups)
            let remove = try Self.groups(request.removeGroupIDs, in: groups)
            let members = build.memberGroupIDs(in: groups)
            let toAdd = add.filter { !members.contains($0.id) }
            let toRemove = remove.filter { members.contains($0.id) }
            let unchanged = (add.filter { members.contains($0.id) } + remove.filter { !members.contains($0.id) }).map(\.name)

            var notes: DistributionNotes?
            if let text = request.notes, let locale = request.locale {
                // Apple's notes are read first: without them, a note cannot be told from a first one, and none is written over them blind.
                guard let existing = await session.testFlightDistributor.notes(for: build.id) else {
                    throw refusal(IPCTestFlightReason.failed, message: String(localized: "The build’s test notes could not be read, so none was written."))
                }
                notes = DistributionNotes(locale: locale, text: text, existing: existing.first { $0.locale == locale })
            }
            let distribution = DistributionRequest(build: build, add: toAdd, remove: toRemove, notes: notes, notify: request.notify)
            guard !distribution.writes.isEmpty else {
                return IPCResult(written: false, unchangedGroups: unchanged)
            }

            let reservation = try reserve(session)
            let outcome = await session.testFlightDistributor.distribute(distribution)
            if outcome.completed.isEmpty, !outcome.isAccepted, !Self.mayHaveReachedApple(outcome) {
                release(reservation, session: session)
            }
            if !outcome.completed.isEmpty || outcome.isAccepted {
                await announceGiven(build: build, productID: productID, added: toAdd, removed: toRemove, session: session)
            }
            return result(for: outcome, session: session, added: toAdd.map(\.name), removed: toRemove.map(\.name), unchanged: unchanged)
        } catch {
            return error.result
        }
    }

    func expire(_ request: IPCTestFlightExpireRequest) async -> IPCResult {
        do throws(Refusal) {
            let session = try await authorizedSession(accountID: request.accountID)
            let (build, _, productID) = try await buildAndGroups(session, buildID: request.testFlightBuildID, needsGroups: false)
            if build.isExpired(at: now()) {
                return IPCResult(written: false, refreshed: true)
            }
            guard TestFlightExpiration.canBeExpired(build, at: now()) else {
                throw refusal(IPCTestFlightReason.buildNotReady, message: String(localized: "Only a processed build can be expired."))
            }

            let reservation = try reserve(session)
            let outcome = await session.testFlightDistributor.expire(buildID: build.id)
            switch outcome {
            case .expired(let read):
                await announceExpired(build: build, productID: productID, session: session)
                return IPCResult(written: true, refreshed: read != nil)
            case .notAllowed(let message):
                release(reservation, session: session)
                session.settings.keyAccess = .readOnly
                return IPCResult(reason: IPCTestFlightReason.notAllowed, message: message, written: false)
            case .refused(let message):
                release(reservation, session: session)
                return IPCResult(reason: IPCTestFlightReason.refused, message: message, written: false)
            case .rateLimited:
                release(reservation, session: session)
                return IPCResult(reason: IPCTestFlightReason.rateLimited, message: outcome.message, written: false)
            case .failed(let message):
                release(reservation, session: session)
                return IPCResult(reason: IPCTestFlightReason.failed, message: message, written: false)
            case .uncertain:
                return IPCResult(reason: IPCTestFlightReason.uncertain, message: outcome.message, written: false)
            }
        } catch {
            return error.result
        }
    }

    // MARK: - Checks

    private func refusal(_ reason: String, message: String? = nil, names: [String]? = nil) -> Refusal {
        Refusal(result: IPCResult(reason: reason, message: message, written: false, names: names))
    }

    /// The account, once the account itself, its key and its access allow a write.
    private func authorizedSession(accountID: String?) async throws(Refusal) -> AccountSession {
        await accounts.whenReady()
        let found = accountID.map { accounts.session(id: $0) } ?? accounts.selected
        guard let session = found else {
            throw refusal(accountID == nil ? IPCTestFlightReason.noCredentials : IPCTestFlightReason.unknownAccount)
        }
        await session.settings.load()
        await session.buildStore.loadCacheIfNeeded()
        guard session.settings.hasStoredKey else { throw refusal(IPCTestFlightReason.noCredentials) }
        guard session.settings.keyAccess == .canLaunch else {
            throw refusal(IPCTestFlightReason.notAllowed, message: String(localized: "The key is set to read-only in Cumulus › Settings › Accounts."))
        }
        let gate = AgentTestFlightGate.allows(writes[session.id] ?? [], now: now())
        guard gate.allowed else {
            let next = gate.nextAt.map { UsageFormat.moment($0) } ?? ""
            throw refusal(
                IPCTestFlightReason.capReached,
                message: String(localized: "Agents already made \(AgentTestFlightGate.cap) TestFlight changes in the last hour; the next is possible at \(next).")
            )
        }
        return session
    }

    /// The build as Apple has it just now (the last reading when it cannot be read), and the groups of its app.
    private func buildAndGroups(_ session: AccountSession, buildID: String, needsGroups: Bool = true) async throws(Refusal) -> (TestFlightBuild, [BetaGroup], String) {
        await session.testFlight.loadCache()
        guard let known = session.testFlight.lookup(buildID: buildID), let appID = session.testFlight.appID(ofBuild: buildID),
              let productID = session.testFlight.readings.first(where: { $0.value.build(id: buildID) != nil })?.key
        else { throw refusal(IPCTestFlightReason.unknownBuild) }
        let build = await session.testFlight.reread(buildID: buildID) ?? known.build
        guard needsGroups else { return (build, session.testFlightGroups.groups(for: appID) ?? [], productID) }
        await session.testFlightGroups.load(appID: appID)
        guard let groups = session.testFlightGroups.groups(for: appID) else {
            throw refusal(IPCTestFlightReason.groupsUnreadable, message: String(localized: "The groups of the app could not be read from App Store Connect."))
        }
        return (build, groups, productID)
    }

    private static func groups(_ ids: [String], in groups: [BetaGroup]) throws(Refusal) -> [BetaGroup] {
        var found: [BetaGroup] = []
        for id in ids {
            guard let group = groups.first(where: { $0.id == id }) else {
                throw Refusal(result: IPCResult(reason: IPCTestFlightReason.unknownGroup, written: false, names: groups.map(\.name)))
            }
            guard !group.receivesEveryBuild else {
                throw Refusal(result: IPCResult(
                    reason: IPCTestFlightReason.groupNotChoosable, message: String(localized: "“\(group.name)” receives every build by itself."), written: false
                ))
            }
            found.append(group)
        }
        return found
    }

    private static func message(for mode: TestFlightDistributionCardModel.Mode) -> String {
        switch mode {
        case .processing: String(localized: "Apple is still processing the build. The groups open when the processing ends.")
        case .processingFailed: String(localized: "Apple could not process this build, so it can’t be distributed.")
        case .missingCompliance: String(localized: "Apple is waiting for your answer about encryption before any distribution.")
        case .expired: String(localized: "An expired build can’t be distributed.")
        case .readOnlyKey: String(localized: "This account’s key is read-only.")
        case .open: ""
        }
    }

    // MARK: - The cap

    /// The write is counted before it is sent, so that two requests at once cannot both pass the cap.
    private func reserve(_ session: AccountSession) throws(Refusal) -> Date {
        let date = now()
        let gate = AgentTestFlightGate.allows(writes[session.id] ?? [], now: date)
        guard gate.allowed else { throw refusal(IPCTestFlightReason.capReached) }
        writes[session.id, default: []].append(date)
        return date
    }

    /// A write that Apple did not take, and that cannot have reached it, does not count.
    private func release(_ date: Date, session: AccountSession) {
        if let index = writes[session.id]?.lastIndex(of: date) {
            writes[session.id]?.remove(at: index)
        }
    }

    private static func mayHaveReachedApple(_ outcome: DistributionOutcome) -> Bool {
        if case .uncertain = outcome { return true }
        return false
    }

    // MARK: - Answers

    private func result(for outcome: DistributionOutcome, session: AccountSession, added: [String], removed: [String], unchanged: [String]) -> IPCResult {
        let steps = outcome.completed.map(\.rawValue)
        switch outcome {
        case .accepted(_, let build):
            return IPCResult(
                written: true, addedGroups: added, removedGroups: removed, unchangedGroups: unchanged, steps: steps, refreshed: build != nil
            )
        case .notAllowed(let message, _):
            session.settings.keyAccess = .readOnly
            return IPCResult(reason: IPCTestFlightReason.notAllowed, message: outcome.message ?? message, written: false, steps: steps)
        case .refused(let message, _, _):
            return IPCResult(reason: IPCTestFlightReason.refused, message: outcome.message ?? message, written: false, steps: steps)
        case .rateLimited:
            return IPCResult(reason: IPCTestFlightReason.rateLimited, message: outcome.message, written: false, steps: steps)
        case .failed(let message, _):
            return IPCResult(reason: IPCTestFlightReason.failed, message: outcome.message ?? message, written: false, steps: steps)
        case .uncertain:
            return IPCResult(reason: IPCTestFlightReason.uncertain, message: outcome.message, written: false, steps: steps)
        }
    }

    // MARK: - Telling the user

    /// The user learns at once that an agent changed who can test a build, wherever they are.
    private func announceGiven(build: TestFlightBuild, productID: String, added: [BetaGroup], removed: [BetaGroup], session: AccountSession) async {
        guard preferences.builds.agentTestFlight else { return }
        let app = appName(productID, session: session)
        var parts = [[app, build.label].joined(separator: " ")]
        if !added.isEmpty {
            parts.append(String(localized: "Given to \(added.map(\.name).formatted(.list(type: .and)))", comment: "Banner body: the placeholder lists the TestFlight groups an agent gave a build to"))
        }
        if !removed.isEmpty {
            parts.append(String(localized: "Taken from \(removed.map(\.name).formatted(.list(type: .and)))", comment: "Banner body: the placeholder lists the TestFlight groups an agent took a build from"))
        }
        await notify([
            LocalNotification(
                id: "agent-testflight-give-\(build.id)-\(Int(now().timeIntervalSince1970))",
                title: added.isEmpty
                    ? String(localized: "TestFlight groups changed by an agent", comment: "Banner title: an agent took a TestFlight build from groups")
                    : String(localized: "TestFlight build given by an agent", comment: "Banner title: an agent gave a TestFlight build to groups"),
                subtitle: accounts.hasSeveral ? session.name : nil, body: UsageFormat.dotted(parts), url: CumulusURL.app(productID: productID), thread: productID
            ),
        ])
    }

    private func announceExpired(build: TestFlightBuild, productID: String, session: AccountSession) async {
        guard preferences.builds.agentTestFlight else { return }
        await notify([
            LocalNotification(
                id: "agent-testflight-expire-\(build.id)",
                title: String(localized: "TestFlight build expired by an agent", comment: "Banner title: an agent expired a TestFlight build, which cannot be undone"),
                subtitle: accounts.hasSeveral ? session.name : nil, body: [appName(productID, session: session), build.label].joined(separator: " "),
                url: CumulusURL.app(productID: productID), thread: productID
            ),
        ])
    }

    private func appName(_ productID: String, session: AccountSession) -> String {
        let product = session.buildStore.snapshot.products.first { $0.id == productID }
        return product?.displayName ?? productID
    }
}
