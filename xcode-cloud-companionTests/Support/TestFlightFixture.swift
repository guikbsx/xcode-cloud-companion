import Foundation
@testable import XcodeCloudCompanion

/// The TestFlight side of the command's account: the build "Alpha#43" delivered, and the groups of Alpha, as the app leaves them
/// in the account's folder of the shared container.
enum TestFlightFixture {
    static let internalAll = BetaGroup(id: "g-all", name: "Internal", isInternal: true, receivesEveryBuild: true, testerCount: 3)
    static let qa = BetaGroup(id: "g-qa", name: "QA", isInternal: true, receivesEveryBuild: false, testerCount: 4)
    static let beta = BetaGroup(id: "g-beta", name: "Beta", isInternal: false, receivesEveryBuild: false, testerCount: 120)
    static let friends = BetaGroup(id: "g-friends", name: "Friends", isInternal: false, receivesEveryBuild: false, testerCount: 8)
    static let groups = [internalAll, qa, beta, friends]

    static let runID = "run-a43"
    static let reference = "Alpha#43"

    static func build(
        id: String = "tf-412", member: [BetaGroup] = [qa], internalState: TestFlightBetaState = .testing, external externalState: TestFlightBetaState = .readyForSubmission,
        processing: TestFlightProcessing = .valid, expired: Bool = false, now: Date = CLIFixture.now
    ) -> TestFlightBuild {
        TestFlightBuild(
            id: id, buildNumber: "412", marketingVersion: "1.4", platform: "IOS", uploadedDate: now.addingTimeInterval(-3600),
            expirationDate: now.addingTimeInterval(80 * 86_400), isMarkedExpired: expired, processing: processing, internalState: internalState,
            externalState: externalState, review: nil, reviewSubmittedDate: nil,
            groups: member.map { TestFlightGroup(name: $0.name, isInternal: $0.isInternal, id: $0.id) }, autoNotifyEnabled: true, betaDetailID: "detail-1"
        )
    }

    /// Writes what the app writes for `runID`: the list of its TestFlight builds, the builds of the app, and its groups.
    static func write(
        to environment: CLIEnvironment, build testFlightBuild: TestFlightBuild? = build(), groups: [BetaGroup]? = groups, listed: Bool = true
    ) async throws {
        let directory = CLIFixture.directory(in: environment)
        if listed {
            let ids = testFlightBuild.map { [CIBetaBuild(id: $0.id, version: $0.buildNumber, uploadedDate: $0.uploadedDate, processingState: "VALID")] } ?? []
            await BuildExtrasCache(directory: directory.appending(path: "BuildDetails")).save(BuildExtras(betaBuilds: ids), runID: runID)
        }
        if let testFlightBuild {
            let reading = TestFlightReading(appID: "111", builds: [testFlightBuild], readAt: CLIFixture.now)
            await TestFlightCache(fileURL: directory.appending(path: "TestFlight.json")).save(TestFlightFile(readings: ["p-alpha": reading]))
        }
        if let groups {
            let reading = BetaGroupsReading(appID: "111", groups: groups, readAt: CLIFixture.now)
            await BetaGroupsCache(fileURL: directory.appending(path: "TestFlightGroups.json")).save(BetaGroupsFile(readings: ["111": reading]))
        }
    }
}
