import Foundation
import Testing
@testable import XcodeCloudCompanion

struct XcodeVersionCheckTests {
    private func version(_ version: String, name: String? = nil) -> CIXcodeVersion {
        CIXcodeVersion(id: version, name: name ?? "Xcode \(version)", version: version)
    }

    @Test func versionsCompareByComponentsNotByText() {
        #expect(XcodeVersionCheck.compare("27.1", "27.0.5") == .orderedDescending)
        #expect(XcodeVersionCheck.compare("27.1", "27.1.0") == .orderedSame)
        #expect(XcodeVersionCheck.compare("9.3", "27.1") == .orderedAscending, "9 is below 27 even though “9” sorts after “2”")
        #expect(XcodeVersionCheck.components("Xcode 27.1 (27B45)") == [27, 1])
        #expect(XcodeVersionCheck.components("unknown") == [])
    }

    @Test func theNewestPublicVersionLeavesBetasAndCandidatesOut() {
        let versions = [
            version("26.4"), version("27.2", name: "Xcode 27.2 beta 2"), version("27.1"), version("27.0"),
            version("27.1.1", name: "Xcode 27.1.1 Release Candidate"), version("28.0", name: "Xcode 28 RC"),
        ]

        #expect(XcodeVersionCheck.latestPublic(in: versions)?.version == "27.1")
        #expect(XcodeVersionCheck.latestPublic(in: []) == nil)
        #expect(XcodeVersionCheck.latestPublic(in: [version("x", name: "Xcode ?")]) == nil, "a version without a number is no candidate")
    }

    @Test func aWorkflowIsWarnedOnlyWhenStrictlyBelowTheNewestPublicVersion() {
        let versions = [version("26.4"), version("27.1"), version("27.2", name: "Xcode 27.2 beta 1")]

        #expect(XcodeVersionCheck.warning(version: "26.4", name: "Xcode 26.4", among: versions) == XcodeVersionCheck.Warning(current: "Xcode 26.4", latest: "Xcode 27.1"))
        #expect(XcodeVersionCheck.warning(version: "27.1", name: nil, among: versions) == nil, "up to date")
        #expect(XcodeVersionCheck.warning(version: "27.2", name: "Xcode 27.2 beta 1", among: versions) == nil, "a beta above the newest public one is not old")
        #expect(XcodeVersionCheck.warning(version: nil, name: "Xcode 26.4", among: versions) == nil, "unknown version")
        #expect(XcodeVersionCheck.warning(version: "26.4", name: nil, among: []) == nil, "unknown list")
        #expect(XcodeVersionCheck.warning(version: "26.4", name: nil, among: versions)?.current == "26.4", "the number stands in for a missing name")
    }

    @Test func theVersionsAreDecodedFromApplesList() async throws {
        let transport = MockTransport { _ in MockTransport.Reply(status: 200, body: (try? Fixture.data("ciXcodeVersions")) ?? Data(), headers: [:]) }
        let client = AppStoreConnectClient(credentials: .sample(), transport: transport)

        let versions = try await client.xcodeVersions()

        #expect(versions.map(\.version) == ["26.4", "27.1", "27.2", "27.0", "27.1.1"])
        #expect(XcodeVersionCheck.latestPublic(in: versions)?.name == "Xcode 27.1")
    }
}
