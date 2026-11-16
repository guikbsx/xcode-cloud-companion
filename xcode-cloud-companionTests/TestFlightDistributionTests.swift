import Foundation
import Synchronization
import Testing
@testable import XcodeCloudCompanion

private let now = Date(timeIntervalSince1970: 1_795_125_600)

private let internalAll = "a11ce009-0000-4000-8000-000000001009"
private let external = "a11ce00a-0000-4000-8000-00000000100a"
private let friends = "a11ce00d-0000-4000-8000-00000000100d"
private let qa = "a11ce00e-0000-4000-8000-00000000100e"

private func groups() throws -> [BetaGroup] {
    try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<BetaGroupAttributes>.self, from: Fixture.data("betaGroups-app")).betaGroups
}

private func group(_ id: String) throws -> BetaGroup {
    let all = try groups()
    return try #require(all.first { $0.id == id })
}

private func build(
    id: String = "b-412", processing: TestFlightProcessing = .valid, internalState: TestFlightBetaState = .ready,
    external externalState: TestFlightBetaState = .readyForSubmission, review: TestFlightReviewState? = nil, member: [String] = [],
    autoNotify: Bool? = nil, expired: Bool = false
) -> TestFlightBuild {
    TestFlightBuild(
        id: id, buildNumber: "412", marketingVersion: "1.4", platform: "IOS", uploadedDate: now.addingTimeInterval(-3600),
        expirationDate: now.addingTimeInterval(80 * 86400), isMarkedExpired: expired, processing: processing, internalState: internalState,
        externalState: externalState, review: review, reviewSubmittedDate: nil,
        groups: member.map { TestFlightGroup(name: "?", isInternal: false, id: $0) }, autoNotifyEnabled: autoNotify, betaDetailID: id
    )
}

// MARK: - Reading the groups

struct BetaGroupsDecodingTests {
    @Test func theGroupsComeInternalFirstEachPartByNameAndTheOneWithoutANameIsLeftOut() throws {
        let read = try groups()

        #expect(read.map(\.name) == ["Internal", "QA", "External testers", "Friends"])
        #expect(read.map(\.isInternal) == [true, true, false, false])
        #expect(read.map(\.receivesEveryBuild) == [true, false, false, false])
        #expect(read.allSatisfy { $0.testerCount == nil })
    }

    @Test func anExternalGroupNeverReceivesEveryBuildEvenIfAppleSaysSo() throws {
        let json = #"{"data": [{"type": "betaGroups", "id": "g1", "attributes": {"name": "Odd", "isInternalGroup": false, "hasAccessToAllBuilds": true}}]}"#

        let read = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<BetaGroupAttributes>.self, from: Data(json.utf8)).betaGroups

        #expect(read.first?.receivesEveryBuild == false)
    }

    @Test func theTesterCountIsAppleTotalOrTheLastPageOrNothing() throws {
        let withTotal = try JSONDecoder().decode(BetaTesterPage.self, from: Fixture.data("betaTesters-relationships"))
        #expect(withTotal.count == 128, "the page holds two identifiers, the total is Apple's")

        let lastPage = try JSONDecoder().decode(BetaTesterPage.self, from: Data(#"{"data": [{"type": "betaTesters", "id": "t1"}, {"type": "betaTesters", "id": "t2"}], "links": {}}"#.utf8))
        #expect(lastPage.count == 2)

        let unknown = try JSONDecoder().decode(
            BetaTesterPage.self, from: Data(#"{"data": [{"type": "betaTesters", "id": "t1"}], "links": {"next": "https://api.appstoreconnect.apple.com/v1/next"}}"#.utf8)
        )
        #expect(unknown.count == nil, "a first page of several says nothing about the whole")
    }

    @Test func theNotesOfABuildAreReadPerLanguageWithoutTextForALanguageNotWrittenYet() throws {
        let notes = try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<BetaBuildLocalizationAttributes>.self, from: Fixture.data("betaBuildLocalizations")).notes

        #expect(notes.map(\.locale) == ["en-US", "fr-FR"])
        #expect(notes[0].text == "New queue widget. Please try dark mode." && notes[1].text == "")
    }

    @Test func aBuildComesWithTheStateOfItsNotificationsAndTheIdentifierOfItsDetail() throws {
        let json = #"""
        {"data": [{"type": "builds", "id": "b1", "attributes": {"version": "9"},
          "relationships": {"buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "detail-1"}}}}],
         "included": [{"type": "buildBetaDetails", "id": "detail-1", "attributes": {"internalBuildState": "MISSING_EXPORT_COMPLIANCE", "externalBuildState": "READY_FOR_BETA_SUBMISSION", "autoNotifyEnabled": false}}]}
        """#

        let read = try #require(try JSONDecoder.appStoreConnect.decode(JSONAPIDocument<TestFlightBuildAttributes>.self, from: Data(json.utf8)).testFlightBuilds.first)

        #expect(read.autoNotifyEnabled == false && read.betaDetailID == "detail-1")
        #expect(read.internalState == .missingCompliance && read.needsExportCompliance)
    }
}

struct BetaGroupsRequestTests {
    @Test func theGroupsOfAnAppAreAskedOnceWithTheirFlagsAndTheirTestersApart() throws {
        let groups = URLRequest(url: AppStoreConnectEndpoint.betaGroups(appID: "1000000001"))
        let testers = AppStoreConnectEndpoint.betaGroupTesters(groupID: "g1")

        #expect(groups.url?.path() == "/v1/apps/1000000001/betaGroups")
        #expect(groups.queryValue("fields[betaGroups]") == "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled")
        #expect(groups.queryValue("limit") == "200")
        #expect(testers.path() == "/v1/betaGroups/g1/relationships/betaTesters")
    }

    @Test func theBuildReadAfterADistributionAsksForTheSameFieldsAsTheListWithTheNotificationSetting() throws {
        let one = URLRequest(url: AppStoreConnectEndpoint.testFlightBuild(id: "b1"))
        let list = URLRequest(url: AppStoreConnectEndpoint.testFlightBuilds(appID: "a1"))

        #expect(one.url?.path() == "/v1/builds/b1")
        for name in ["include", "fields[builds]", "fields[buildBetaDetails]", "fields[betaGroups]", "fields[betaAppReviewSubmissions]"] {
            #expect(one.queryValue(name) == list.queryValue(name), "\(name)")
        }
        #expect(one.queryValue("fields[buildBetaDetails]")?.contains("autoNotifyEnabled") == true)
    }
}

// MARK: - Request bodies

struct BetaWriteBodyTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theGroupsGoInOneBodyForTheAdditionAndTheRemoval() throws {
        let request = BetaGroupMembershipRequest(buildID: "b1", groupIDs: ["g1", "g2"])

        let body = try object(request.body())
        let data = try #require(body["data"] as? [[String: String]])

        #expect(Set(body.keys) == ["data"])
        #expect(data == [["type": "betaGroups", "id": "g1"], ["type": "betaGroups", "id": "g2"]])
        #expect(AppStoreConnectEndpoint.buildBetaGroups(buildID: "b1").path() == "/v1/builds/b1/relationships/betaGroups")
    }

    @Test(arguments: [
        BetaGroupMembershipRequest(buildID: "", groupIDs: ["g1"]),
        BetaGroupMembershipRequest(buildID: "b1", groupIDs: []),
        BetaGroupMembershipRequest(buildID: "b1", groupIDs: ["g1", "g1"]),
        BetaGroupMembershipRequest(buildID: "b1", groupIDs: ["../g"]),
        BetaGroupMembershipRequest(buildID: "b/1", groupIDs: ["g1"]),
    ])
    func aMalformedMembershipIsNeverSent(request: BetaGroupMembershipRequest) {
        #expect(!request.isWellFormed)
    }

    @Test func aFirstNoteCreatesTheLocalizationOfTheBuildAndALaterOneOnlyChangesItsText() throws {
        let create = BetaNoteRequest(buildID: "b1", kind: .create(locale: "fr-FR"), text: "Merci de tester.")
        let update = BetaNoteRequest(buildID: "b1", kind: .update(localizationID: "loc-1"), text: "Thanks.")

        let created = try #require(try object(create.body())["data"] as? [String: Any])
        #expect(created["type"] as? String == "betaBuildLocalizations" && created["id"] == nil)
        #expect(created["attributes"] as? [String: String] == ["locale": "fr-FR", "whatsNew": "Merci de tester."])
        let relationships = try #require(created["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["build"]?["data"] == ["type": "builds", "id": "b1"])

        let updated = try #require(try object(update.body())["data"] as? [String: Any])
        #expect(updated["id"] as? String == "loc-1" && updated["relationships"] == nil)
        #expect(updated["attributes"] as? [String: String] == ["whatsNew": "Thanks."], "the language is not sent again")
        #expect(AppStoreConnectEndpoint.betaBuildLocalization(id: "loc-1").path() == "/v1/betaBuildLocalizations/loc-1")
        #expect(AppStoreConnectEndpoint.createBetaBuildLocalization.path() == "/v1/betaBuildLocalizations")
    }

    @Test func aNoteLongerThanAppleAllowsOrWithABadLocaleIsNeverSent() {
        #expect(!BetaNoteRequest(buildID: "b1", kind: .create(locale: "fr-FR"), text: String(repeating: "a", count: 4001)).isWellFormed)
        #expect(BetaNoteRequest(buildID: "b1", kind: .create(locale: "fr-FR"), text: String(repeating: "a", count: 4000)).isWellFormed)
        #expect(!BetaNoteRequest(buildID: "b1", kind: .create(locale: "fr FR"), text: "x").isWellFormed)
        #expect(!BetaNoteRequest(buildID: "b1", kind: .update(localizationID: ""), text: "x").isWellFormed)
    }

    @Test func theNotificationSettingAndTheReviewSubmissionCarryOnlyWhatTheyNeed() throws {
        let notify = try #require(try object(BuildAutoNotifyRequest(detailID: "d1", isEnabled: false).body())["data"] as? [String: Any])
        #expect(notify["type"] as? String == "buildBetaDetails" && notify["id"] as? String == "d1")
        #expect(notify["attributes"] as? [String: Bool] == ["autoNotifyEnabled": false])
        #expect(AppStoreConnectEndpoint.buildBetaDetail(id: "d1").path() == "/v1/buildBetaDetails/d1")

        let review = try #require(try object(BetaReviewSubmissionRequest(buildID: "b1").body())["data"] as? [String: Any])
        #expect(review["type"] as? String == "betaAppReviewSubmissions" && review["id"] == nil && review["attributes"] == nil)
        let relationships = try #require(review["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["build"]?["data"] == ["type": "builds", "id": "b1"])
        #expect(AppStoreConnectEndpoint.createBetaAppReviewSubmission.path() == "/v1/betaAppReviewSubmissions")
    }
}

// MARK: - What would change

struct DistributionPlanTests {
    @Test func theBoxesCheckedAgainstTheGroupsTheBuildIsInGiveWhatToAddAndWhatToRemove() throws {
        let all = try groups()
        let members: Set = [internalAll, external]

        let plan = TestFlightDistributionPlan.make(groups: all, members: members, selected: [internalAll, qa, friends])

        #expect(plan.toAdd.map(\.name) == ["QA", "Friends"])
        #expect(plan.toRemove.map(\.name) == ["External testers"])
        #expect(plan.addsExternalGroup && !plan.isEmpty)
        #expect(TestFlightDistributionPlan.make(groups: all, members: members, selected: members).isEmpty)
    }

    @Test func aGroupThatGetsEveryBuildIsNeverAskedToLeaveOrJoin() throws {
        let all = try groups()

        let uncheck = TestFlightDistributionPlan.make(groups: all, members: [internalAll], selected: [])
        #expect(uncheck.isEmpty, "it can't be unchecked")
        let notMember = TestFlightDistributionPlan.make(groups: all, members: [], selected: [internalAll])
        #expect(notMember.isEmpty, "Apple does not list it for the build, yet it has it")
    }

    @Test func theGroupsOfABuildAreThoseAppleListsAndTheOnesThatGetEveryBuild() throws {
        let all = try groups()
        let listed = build(member: [external])
        let byName = TestFlightBuild(
            id: "b", buildNumber: "1", marketingVersion: nil, platform: nil, uploadedDate: nil, expirationDate: nil, isMarkedExpired: false,
            processing: .valid, internalState: .testing, externalState: .testing, review: nil, reviewSubmittedDate: nil,
            groups: [TestFlightGroup(name: "Friends", isInternal: false), TestFlightGroup(name: "Gone", isInternal: false, id: "gone")]
        )

        #expect(TestFlightDistributionPlan.members(of: listed, in: all) == [internalAll, external])
        #expect(TestFlightDistributionPlan.members(of: byName, in: all) == [internalAll, friends], "an old reading names its groups; a group that no longer exists is dropped")
    }

    @Test func theFootSaysWhatWillChange() throws {
        let all = try groups()
        func summary(_ members: Set<String>, _ selected: Set<String>) -> String? {
            TestFlightDistributionText.summary(TestFlightDistributionPlan.make(groups: all, members: members, selected: selected))
        }

        #expect(summary([], []) == nil)
        #expect(summary([], [qa]) == "1 group to add")
        #expect(summary([], [qa, friends]) == "2 groups to add")
        #expect(summary([qa], []) == "1 to remove")
        #expect(summary([qa], [friends]) == "1 group to add · 1 to remove")
    }

    @Test func theNotesAreWrittenOnlyWhenTheyChangedAndAFirstLanguageNeedsText() {
        let existing = BetaBuildNote(id: "loc-1", locale: "en-US", text: "Try dark mode.")

        #expect(DistributionNotes(locale: "en-US", text: "  Try dark mode.\n", existing: existing).request(buildID: "b1") == nil, "same text, blanks aside")
        #expect(DistributionNotes(locale: "en-US", text: "Try light mode.", existing: existing).request(buildID: "b1")
            == BetaNoteRequest(buildID: "b1", kind: .update(localizationID: "loc-1"), text: "Try light mode."))
        #expect(DistributionNotes(locale: "fr-FR", text: "Testez.", existing: nil).request(buildID: "b1")
            == BetaNoteRequest(buildID: "b1", kind: .create(locale: "fr-FR"), text: "Testez."))
        #expect(DistributionNotes(locale: "fr-FR", text: " \n", existing: nil).request(buildID: "b1") == nil, "nothing to write on a language with no notes")
        #expect(DistributionNotes(locale: "en-US", text: "", existing: existing).request(buildID: "b1")
            == BetaNoteRequest(buildID: "b1", kind: .update(localizationID: "loc-1"), text: ""), "notes can be emptied")
    }

    @Test func theWritesGoNotesFirstThenTheNotificationThenTheGroups() throws {
        let existing = BetaBuildNote(id: "loc-1", locale: "en-US", text: "Old.")
        let request = DistributionRequest(
            build: build(autoNotify: true), add: [try group(qa)], remove: [try group(external)],
            notes: DistributionNotes(locale: "en-US", text: "New.", existing: existing), notify: false
        )

        #expect(request.writes.map(\.step) == [.notes, .notification, .addGroups, .removeGroups])
        let wellFormed = request.writes.allSatisfy { $0.isWellFormed }
        #expect(wellFormed)
        let same = DistributionRequest(build: build(autoNotify: true), add: [try group(qa)], notes: nil, notify: true)
        #expect(same.writes.map(\.step) == [.addGroups], "the testers are already told: nothing to change")
    }
}

// MARK: - What the card shows

struct DistributionCardModelTests {
    private func model(_ build: TestFlightBuild, canWrite: Bool = true) throws -> TestFlightDistributionCardModel {
        .make(build: build, groups: try groups(), canWrite: canWrite, now: now, locale: Locale(identifier: "en_US"))
    }

    @Test func anOpenBuildListsItsGroupsInTwoBlocksWithTheOnesItIsInChecked() throws {
        let card = try model(build(internalState: .testing, external: .waitingForReview, review: .waiting, member: [external]))

        #expect(card.mode == .open && card.isEditable && card.label == "1.4 (412)")
        #expect(card.internalRows.map(\.name) == ["Internal", "QA"] && card.externalRows.map(\.name) == ["External testers", "Friends"])
        #expect(card.rows.map(\.isMember) == [true, false, true, false])
        let all = try #require(card.internalRows.first)
        #expect(all.receivesEveryBuild && all.note == "Receives every build")
        #expect(card.externalRows.allSatisfy { $0.note == "Apple beta review first" })
        #expect(card.internalRows[1].note == nil)
    }

    @Test func eachMemberGroupSaysWhatAppleSaysOfItNotWhatWasAskedFor() throws {
        let waiting = try model(build(internalState: .testing, external: .waitingForReview, review: .waiting, member: [external]))
        #expect(waiting.rows.map { $0.badge?.tone } == [.available, nil, .awaitingReview, nil])
        #expect(waiting.rows.first { $0.id == external }?.badge?.text == "Awaiting review")

        let reviewing = try model(build(internalState: .testing, external: .inReview, review: .inReview, member: [external]))
        #expect(reviewing.rows.first { $0.id == external }?.badge?.tone == .inReview)

        let live = try model(build(internalState: .testing, external: .testing, review: .approved, member: [external, qa]))
        #expect(live.rows.compactMap(\.badge?.tone) == [.available, .available, .available])
        #expect(live.rows.first { $0.id == friends }?.badge == nil, "a group the build is not in says nothing")

        let rejected = try model(build(internalState: .testing, external: .rejected, review: .rejected, member: [external]))
        #expect(rejected.rows.first { $0.id == external }?.badge?.tone == .rejected)
    }

    @Test func eachStateOfTheMockupHasItsMode() throws {
        #expect(try model(build(processing: .processing, internalState: .processing, external: .processing)).mode == .processing)
        #expect(try model(build(processing: .processing, internalState: .processing, external: .processing)).showsGroups)
        #expect(try model(build(processing: .processing, internalState: .processing, external: .processing)).isEditable == false)
        #expect(try model(build(processing: .failed)).mode == .processingFailed)

        let compliance = try model(build(internalState: .missingCompliance))
        #expect(compliance.mode == .missingCompliance && !compliance.showsGroups && compliance.statusText == "To complete")
        #expect(compliance.message == "Apple is waiting for your answer about encryption before any distribution.")

        let readOnly = try model(build(), canWrite: false)
        #expect(readOnly.mode == .readOnlyKey && !readOnly.showsGroups && readOnly.statusText == "Ready")

        let expired = try model(build(internalState: .expired, external: .expired, expired: true))
        #expect(expired.mode == .expired && expired.showsGroups && !expired.isEditable)
        #expect(expired.message == "An expired build can’t be distributed.")
    }

    @Test func theTesterCountIsSaidWhenKnownAndLeftOutWhenNot() throws {
        var counted = try groups()
        counted[1].testerCount = 2

        let card = TestFlightDistributionCardModel.make(build: build(), groups: counted, canWrite: true, now: now, locale: Locale(identifier: "en_US"))

        #expect(card.rows.map(\.testers) == [nil, "2 testers", nil, nil])
    }

    @Test func theConfirmationNamesTheBuildAndEachGroupWithItsChip() throws {
        var qaGroup = try group(qa)
        qaGroup.testerCount = 2
        var publicGroup = try group(external)
        publicGroup.testerCount = 128
        let plan = TestFlightDistributionPlan(toAdd: [qaGroup, publicGroup], toRemove: [try group(friends)])

        let sheet = TestFlightDistributionSheetModel.make(label: "1.4 (412)", plan: plan)

        #expect(sheet.title == "Change the groups of 1.4 (412)?" && sheet.confirmButton == "Give Access")
        #expect(sheet.lines.map(\.title) == ["QA · 2 testers", "External testers · 128 testers", "Friends"])
        #expect(sheet.lines.map(\.chip.text) == ["Right away", "Beta review", "Removed"])
        #expect(sheet.lines[0].detail == "available right away" && sheet.lines[1].detail == "Apple beta review first")

        let adding = TestFlightDistributionSheetModel.make(label: "1.4 (412)", plan: TestFlightDistributionPlan(toAdd: [qaGroup, publicGroup], toRemove: []))
        #expect(adding.title == "Give 1.4 (412) to 2 groups?")
        let removing = TestFlightDistributionSheetModel.make(label: "1.4 (412)", plan: TestFlightDistributionPlan(toAdd: [], toRemove: [qaGroup]))
        #expect(removing.title == "Take 1.4 (412) from 1 group?" && removing.confirmButton == "Remove Access")
    }

    @Test func theNotesLanguagesAreThoseOfTheBuildOrAStartingPair() {
        #expect(TestFlightNoteLocales.choices(existing: []) == ["en-US", "fr-FR"])
        #expect(TestFlightNoteLocales.choices(existing: [BetaBuildNote(id: "1", locale: "de-DE", text: "")]) == ["de-DE"])
        #expect(TestFlightNoteLocales.initial(choices: ["en-US", "fr-FR"], preferred: ["fr-FR", "en-US"]) == "fr-FR")
        #expect(TestFlightNoteLocales.initial(choices: ["en-US", "fr-FR"], preferred: ["ja-JP"]) == "en-US")
    }

    @Test func theSkeletonWaitsOnlyForTheFirstReadOfTheGroups() {
        #expect(SkeletonRules.testFlightGroups(hasGroups: false, hasAttempted: false))
        #expect(!SkeletonRules.testFlightGroups(hasGroups: true, hasAttempted: false), "the groups of the last session show at once")
        #expect(!SkeletonRules.testFlightGroups(hasGroups: false, hasAttempted: true), "a read that ended with nothing leaves the place as it was")
    }

}

// MARK: - Sending

@MainActor
struct TestFlightDistributorTests {
    private final class Log: Sendable {
        let writes = Mutex<[URLRequest]>([])
        let rereads = Mutex<Int>(0)
        let notesRead = Mutex<Int>(0)
    }

    /// `replies` answers a write by its method and path; a write nobody planned answers 204.
    private func distributor(
        log: Log, replies: @escaping @Sendable (URLRequest) -> MockTransport.Reply? = { _ in nil },
        reread: @escaping @Sendable (Int) -> TestFlightBuild? = { _ in nil }, writable: Bool = true
    ) -> TestFlightDistributor {
        let transport = MockTransport { request in
            if request.httpMethod == "GET" || request.httpMethod == nil {
                log.notesRead.withLock { $0 += 1 }
                return MockTransport.Reply(body: (try? Fixture.data("betaBuildLocalizations")) ?? Data())
            }
            log.writes.withLock { $0.append(request) }
            return replies(request) ?? MockTransport.Reply(status: 204)
        }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        return TestFlightDistributor(
            client: { client },
            reread: { _ in
                let count = log.rereads.withLock { value -> Int in
                    value += 1
                    return value
                }
                return reread(count)
            },
            isKeyWritable: { writable }
        )
    }

    private func request(
        build: TestFlightBuild = build(), add: [String] = [qa], remove: [String] = [], notes: DistributionNotes? = nil, notify: Bool? = nil
    ) throws -> DistributionRequest {
        DistributionRequest(build: build, add: try add.map { try group($0) }, remove: try remove.map { try group($0) }, notes: notes, notify: notify)
    }

    private func shape(_ requests: [URLRequest]) -> [String] {
        requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" }
    }

    @Test func theGroupsAreAddedByOnePostAndRemovedByOneDeleteAndTheBuildIsReadBack() async throws {
        let log = Log()
        let after = build(internalState: .testing, member: [qa])

        let outcome = await distributor(log: log, reread: { _ in after }).distribute(try request(add: [qa], remove: [friends]))

        #expect(outcome == .accepted(completed: [.addGroups, .removeGroups], build: after))
        #expect(outcome.message == nil)
        let sent = log.writes.withLock { $0 }
        #expect(shape(sent) == ["POST /v1/builds/b-412/relationships/betaGroups", "DELETE /v1/builds/b-412/relationships/betaGroups"])
        let addedBody = try #require(sent[0].httpBody)
        let removedBody = try #require(sent[1].httpBody)
        let added = try #require(try JSONSerialization.jsonObject(with: addedBody) as? [String: [[String: String]]])
        let removed = try #require(try JSONSerialization.jsonObject(with: removedBody) as? [String: [[String: String]]])
        #expect(added["data"]?.map { $0["id"] } == [qa] && removed["data"]?.map { $0["id"] } == [friends])
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        #expect(log.rereads.withLock { $0 } == 1)
    }

    @Test func theNotesAreWrittenBeforeTheGroupsAndTheNotificationSettingBetweenThem() async throws {
        let log = Log()
        let existing = BetaBuildNote(id: "loc-1", locale: "en-US", text: "Old.")
        let notes = DistributionNotes(locale: "en-US", text: "New.", existing: existing)

        let outcome = await distributor(log: log).distribute(try request(build: build(autoNotify: true), notes: notes, notify: false))

        #expect(outcome.completed == [.notes, .notification, .addGroups])
        #expect(shape(log.writes.withLock { $0 }) == [
            "PATCH /v1/betaBuildLocalizations/loc-1", "PATCH /v1/buildBetaDetails/b-412", "POST /v1/builds/b-412/relationships/betaGroups",
        ])
    }

    @Test func notesThatDidNotChangeSendNothing() async throws {
        let log = Log()
        let existing = BetaBuildNote(id: "loc-1", locale: "en-US", text: "Same.")

        let outcome = await distributor(log: log).distribute(try request(notes: DistributionNotes(locale: "en-US", text: "Same.", existing: existing)))

        #expect(outcome.completed == [.addGroups])
        #expect(shape(log.writes.withLock { $0 }) == ["POST /v1/builds/b-412/relationships/betaGroups"])
    }

    @Test func anExternalGroupWithoutASubmissionIsSentToTheBetaReviewAfterTheAddition() async throws {
        let log = Log()
        let unsubmitted = build(internalState: .testing, external: .readyForSubmission, member: [external])
        let submitted = build(internalState: .testing, external: .waitingForReview, review: .waiting, member: [external])

        // The first read (after the addition) shows no submission; the last one shows Apple's.
        let outcome = await distributor(log: log, reread: { $0 == 1 ? unsubmitted : submitted }).distribute(try request(add: [external]))

        #expect(shape(log.writes.withLock { $0 }) == ["POST /v1/builds/b-412/relationships/betaGroups", "POST /v1/betaAppReviewSubmissions"])
        #expect(outcome == .accepted(completed: [.addGroups, .betaReview], build: submitted))
        #expect(TestFlightDistributor.needsBetaReview(unsubmitted) && !TestFlightDistributor.needsBetaReview(submitted))
    }

    @Test func anExternalGroupThatApplesAdditionAlreadySubmittedIsNotSubmittedAgain() async throws {
        let log = Log()
        let alreadyWaiting = build(internalState: .testing, external: .waitingForReview, review: .waiting, member: [external])

        let outcome = await distributor(log: log, reread: { _ in alreadyWaiting }).distribute(try request(add: [external]))

        #expect(shape(log.writes.withLock { $0 }) == ["POST /v1/builds/b-412/relationships/betaGroups"])
        #expect(outcome == .accepted(completed: [.addGroups], build: alreadyWaiting))
        #expect(!TestFlightDistributor.needsBetaReview(nil), "a build that could not be read is not submitted blind")
        #expect(!TestFlightDistributor.needsBetaReview(build(external: .testing)), "already in testing outside")
    }

    @Test func anInternalGroupNeverAsksForTheBetaReview() async throws {
        let log = Log()

        _ = await distributor(log: log, reread: { _ in build(external: .readyForSubmission) }).distribute(try request(add: [qa]))

        #expect(shape(log.writes.withLock { $0 }) == ["POST /v1/builds/b-412/relationships/betaGroups"])
        #expect(log.rereads.withLock { $0 } == 1, "one read at the end, none to decide on a review")
    }

    @Test func aKeyThatIsReadOnlySendsNothing() async throws {
        let log = Log()

        let outcome = await distributor(log: log, writable: false).distribute(try request())

        #expect(outcome == .notAllowed(message: DistributionOutcome.readOnlyMessage, completed: []))
        #expect(log.writes.withLock { $0.isEmpty } && log.rereads.withLock { $0 } == 0)
    }

    @Test func nothingToChangeAndAMalformedIdentifierAreNeverSent() async throws {
        let log = Log()
        let service = distributor(log: log)

        let empty = await service.distribute(DistributionRequest(build: build(), add: [], remove: [], notes: nil, notify: nil))
        var odd = try group(qa)
        odd.id = "../x"
        let malformed = await service.distribute(DistributionRequest(build: build(), add: [odd]))

        guard case .failed = empty, case .failed = malformed else {
            Issue.record("expected failures, got \(empty) and \(malformed)")
            return
        }
        #expect(log.writes.withLock { $0.isEmpty })
    }

    @Test func aForbiddenKeyIsToldAnAdminOrAppManagerKeyIsNeeded() async throws {
        let log = Log()
        let body = Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"x","detail":"no"}]}"#.utf8)

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 403, body: body) }).distribute(try request())

        #expect(outcome == .notAllowed(message: "This key can’t distribute builds. It needs an Admin or App Manager key.", completed: []))
        #expect(log.writes.withLock { $0.count } == 1 && log.rereads.withLock { $0 } == 0)
    }

    @Test(arguments: [409, 422])
    func aRefusalShowsApplesWordsAndIsNotRetried(status: Int) async throws {
        let log = Log()
        let body = Data(#"{"errors":[{"status":"\#(status)","code":"ENTITY_ERROR","title":"Beta App Description missing","detail":"Beta App Description is required for external testing."}]}"#.utf8)

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: status, body: body) }).distribute(try request(add: [external]))

        let words = "Beta App Description missing Beta App Description is required for external testing."
        #expect(outcome == .refused(message: words, step: .addGroups, completed: []))
        #expect(outcome.message == words, "Apple's words as they are, nothing else was done")
        #expect(log.writes.withLock { $0.count } == 1 && log.rereads.withLock { $0 } == 0, "nothing changed: nothing to read back")
    }

    @Test func aRateLimitStopsEverythingThatFollows() async throws {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 429) }).distribute(try request(add: [qa], remove: [friends]))

        #expect(outcome == .rateLimited(completed: []))
        #expect(log.writes.withLock { $0.count } == 1, "the removal is not sent after the refusal of the addition")
    }

    @Test func aTimeoutIsFollowedByAReadNeverByASecondWrite() async throws {
        let log = Log()
        let truth = build(internalState: .testing, member: [qa])

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(error: URLError(.timedOut)) }, reread: { _ in truth })
            .distribute(try request(add: [qa], remove: [friends]))

        #expect(outcome == .uncertain(step: .addGroups, completed: [], build: truth))
        #expect(outcome.message?.contains("look them over before trying again") == true)
        #expect(log.writes.withLock { $0.count } == 1, "the removal waits for the user to look at the truth")
        #expect(log.rereads.withLock { $0 } == 1)
    }

    @Test func aServerErrorIsAmbiguousAndSoIsAReadThatFailsToo() async throws {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(status: 500) }).distribute(try request())

        #expect(outcome == .uncertain(step: .addGroups, completed: [], build: nil))
        #expect(outcome.message?.contains("Check it in App Store Connect before trying again") == true)
        #expect(log.writes.withLock { $0.count } == 1)
    }

    @Test func aNetworkThatNeverLeftTheMacIsAPlainFailureWithNoRead() async throws {
        let log = Log()

        let outcome = await distributor(log: log, replies: { _ in MockTransport.Reply(error: URLError(.notConnectedToInternet)) }).distribute(try request())

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(log.rereads.withLock { $0 } == 0)
    }

    @Test func aRefusalAfterTheNotesWereWrittenSaysWhatWasDoneAndReadsTheBuildBack() async throws {
        let log = Log()
        let body = Data(#"{"errors":[{"status":"409","code":"X","title":"Refused","detail":"No."}]}"#.utf8)
        let notes = DistributionNotes(locale: "en-US", text: "Try it.", existing: nil)

        let outcome = await distributor(log: log, replies: { $0.httpMethod == "POST" && $0.url?.path().hasSuffix("betaGroups") == true ? MockTransport.Reply(status: 409, body: body) : nil })
            .distribute(try request(notes: notes))

        #expect(outcome == .refused(message: "Refused No.", step: .addGroups, completed: [.notes]))
        #expect(outcome.message == "Already done: the test notes. Refused No.")
        #expect(log.rereads.withLock { $0 } == 1, "something changed, so the card must be able to show it")
        #expect(log.writes.withLock { $0.count } == 2)
    }

    @Test func aSecondDistributionWhileOneIsInFlightIsRefused() async throws {
        let log = Log()
        let service = distributor(log: log)

        let one = try request()
        let two = try request()
        async let first = service.distribute(one)
        async let second = service.distribute(two)
        let outcomes = await [first, second]

        #expect(outcomes.filter(\.isAccepted).count == 1)
        #expect(log.writes.withLock { $0.count } == 1)
    }

    @Test func theNotesOfABuildAreReadOnceWhenAsked() async throws {
        let log = Log()

        let notes = await distributor(log: log).notes(for: "b-412")

        #expect(notes?.map(\.locale) == ["en-US", "fr-FR"])
        #expect(log.notesRead.withLock { $0 } == 1)
    }
}

// MARK: - The stores

@MainActor
struct TestFlightGroupsStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "cumulus-groups-\(UUID().uuidString)")

    private func transport(counts: Bool = true) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/betaGroups") { return MockTransport.Reply(body: (try? Fixture.data("betaGroups-app")) ?? Data()) }
            if path.hasSuffix("/betaTesters") {
                return counts ? MockTransport.Reply(body: (try? Fixture.data("betaTesters-relationships")) ?? Data()) : MockTransport.Reply(status: 500)
            }
            return MockTransport.Reply(status: 404)
        }
    }

    private func store(_ transport: MockTransport, budget: RateLimit? = nil, clock: TestClock = TestClock(now)) -> TestFlightGroupsStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let store = TestFlightGroupsStore(
            cache: BetaGroupsCache(fileURL: directory.appending(path: "TestFlightGroups.json")), client: { client }, budget: { budget }, now: { clock.now }
        )
        return store
    }

    @Test func theGroupsOfAnAppAreReadOnceASessionWithOneCountRequestPerGroup() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()
        let store = store(transport)

        await store.load(appID: "app-1")
        await store.load(appID: "app-1")

        let groups = try #require(store.groups(for: "app-1"))
        #expect(groups.map(\.name) == ["Internal", "QA", "External testers", "Friends"])
        #expect(groups.allSatisfy { $0.testerCount == 128 })
        let paths = await transport.requests.map { $0.url?.path() ?? "" }
        #expect(paths.filter { $0.hasSuffix("/betaGroups") }.count == 1, "the second call asks for nothing")
        #expect(paths.filter { $0.hasSuffix("/betaTesters") }.count == 4)
        #expect(store.hasAttempted("app-1") && !store.hasAttempted("app-2"))
    }

    @Test func aCountThatCouldNotBeReadIsLeftOutNotZero() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(transport(counts: false))

        await store.load(appID: "app-1")

        #expect(store.groups(for: "app-1")?.count == 4)
        #expect(store.groups(for: "app-1")?.allSatisfy { $0.testerCount == nil } == true)
    }

    @Test func theFileInTheAccountsFolderLetsTheNextSessionDrawAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        await store(transport()).load(appID: "app-1")

        let next = store(MockTransport { _ in MockTransport.Reply(error: URLError(.notConnectedToInternet)) })
        await next.loadCache()

        #expect(next.groups(for: "app-1")?.map(\.name) == ["Internal", "QA", "External testers", "Friends"])
        #expect(next.groups(for: "app-1")?.first?.testerCount == 128)
        #expect(!next.hasAttempted("app-1"), "the skeleton is not needed, and nothing was asked yet")

        await next.load(appID: "app-1")
        #expect(next.groups(for: "app-1")?.count == 4, "an offline read keeps what the file said")
    }

    @Test func withTheBudgetNearlySpentNothingIsAsked() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let spent = transport()
        let spentStore = store(spent, budget: RateLimit(limit: 3600, remaining: SyncSchedule.criticalRemaining))
        await spentStore.load(appID: "app-1")
        #expect(await spent.requests.isEmpty && spentStore.groups(for: "app-1") == nil)
        #expect(spentStore.hasAttempted("app-1"), "the skeleton does not wait for a read that will not come")
    }

    @Test func aFailedReadWaitsItsTurnAndAForbiddenKeyIsNotAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now)
        let failing = MockTransport { _ in MockTransport.Reply(status: 500) }
        let store = store(failing, clock: clock)

        await store.load(appID: "app-1")
        await store.load(appID: "app-1")
        #expect(await failing.requests.count == 1)
        clock.advance(by: TestFlightGroupsStore.retryInterval + 1)
        await store.load(appID: "app-1")
        #expect(await failing.requests.count == 2)

        let forbidden = MockTransport { _ in MockTransport.Reply(status: 403, body: (try? Fixture.data("errorResponse")) ?? Data()) }
        let forbiddenStore = self.store(forbidden)
        await forbiddenStore.load(appID: "app-1")
        await forbiddenStore.load(appID: "app-2")
        #expect(forbiddenStore.isForbidden && forbiddenStore.groups(for: "app-1") == nil)
        #expect(await forbidden.requests.count == 1)
    }

    @Test func resettingTheKeyForgetsTheGroupsAndTheirFile() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(transport())
        await store.load(appID: "app-1")
        let file = directory.appending(path: "TestFlightGroups.json")
        #expect(FileManager.default.fileExists(atPath: file.path()))

        await store.reset()

        #expect(store.groups(for: "app-1") == nil && !FileManager.default.fileExists(atPath: file.path()))
    }

    @Test func theFileLivesInTheAccountsFolderAndGoesWithIt() {
        let paths = AccountPaths(accountID: "acc-1", supportRoot: directory, cachesRoot: directory)

        #expect(paths.testFlightGroups.path().hasPrefix(paths.support.path()))
        #expect(paths.testFlightGroups.lastPathComponent == "TestFlightGroups.json")
    }
}

@MainActor
struct TestFlightRereadTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "cumulus-reread-\(UUID().uuidString)")

    private func store(_ transport: MockTransport) -> TestFlightStore {
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)
        let store = TestFlightStore(
            cache: TestFlightCache(fileURL: directory.appending(path: "TestFlight.json")), client: { client }, budget: { nil }, now: { now }
        )
        return store
    }

    private func seeded(_ store: TestFlightStore) async throws -> TestFlightBuild {
        let before = build(id: "b-412", internalState: .testing)
        let file = TestFlightFile(readings: ["p1": TestFlightReading.following(nil, appID: "app-1", builds: [before], at: now.addingTimeInterval(-600))])
        await TestFlightCache(fileURL: directory.appending(path: "TestFlight.json")).save(file)
        await store.loadCache()
        return before
    }

    @Test func oneBuildIsReadAgainAndTakesItsPlaceInTheReading() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"""
        {"data": {"type": "builds", "id": "b-412", "attributes": {"version": "412", "processingState": "VALID", "uploadedDate": "2026-11-19T20:00:00Z"},
          "relationships": {"buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "b-412"}}, "betaGroups": {"data": [{"type": "betaGroups", "id": "g-qa"}]}}},
         "included": [{"type": "buildBetaDetails", "id": "b-412", "attributes": {"internalBuildState": "IN_BETA_TESTING", "externalBuildState": "READY_FOR_BETA_SUBMISSION"}},
                      {"type": "betaGroups", "id": "g-qa", "attributes": {"name": "QA", "isInternalGroup": true}}]}
        """#
        let transport = MockTransport { _ in MockTransport.Reply(body: Data(json.utf8)) }
        let store = store(transport)
        _ = try await seeded(store)

        let read = await store.reread(buildID: "b-412")

        #expect(read?.groups.map(\.id) == ["g-qa"])
        #expect(store.lookup(buildID: "b-412")?.build.groups.map(\.name) == ["QA"])
        #expect(store.appID(ofBuild: "b-412") == "app-1" && store.appID(ofBuild: "nope") == nil)
        let requests = await transport.requests
        #expect(requests.count == 1 && requests.first?.url?.path() == "/v1/builds/b-412")
        let kept = await TestFlightCache(fileURL: directory.appending(path: "TestFlight.json")).load()
        #expect(kept?.readings["p1"]?.builds.first?.groups.map(\.id) == ["g-qa"], "the file follows")
    }

    @Test func aBuildNoReadingKnowsIsNotAsked() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport { _ in MockTransport.Reply(status: 500) }
        let open = store(transport)
        _ = try await seeded(open)
        #expect(await open.reread(buildID: "unknown") == nil)
        #expect(await open.reread(buildID: "b-412") == nil, "a failed read gives nothing")
        #expect(open.lookup(buildID: "b-412")?.build.internalState == .testing, "and changes nothing")
    }
}
