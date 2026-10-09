import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct MenuBarBadgeTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func run(
        _ number: Int, minutesAgo: Double, progress: CIExecutionProgress = .complete, status: CICompletionStatus? = .succeeded, ranFor minutes: Double = 5
    ) -> CIBuildRun {
        let created = now.addingTimeInterval(-minutesAgo * 60)
        return CIBuildRun(
            id: "r\(number)", productID: "p", number: number, createdDate: created, startedDate: created,
            finishedDate: progress == .complete ? created.addingTimeInterval(minutes * 60) : nil, executionProgress: progress,
            completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: nil, workflowName: nil, sourceBranchOrTag: nil
        )
    }

    private func badge(_ runs: [CIBuildRun]) -> MenuBarBadge? {
        MenuBarBadge.status(for: BuildSnapshot(runs: runs))
    }

    @Test func aRunningBuildAnywhereWins() {
        #expect(badge([run(2, minutesAgo: 3, progress: .running), run(1, minutesAgo: 30, status: .failed)]) == .running)
        #expect(badge([run(1, minutesAgo: 2, progress: .pending)]) == .running)
    }

    @Test func aRunningBuildStaysBlueEvenIfNewerOnesFinished() {
        #expect(badge([run(1, minutesAgo: 120, progress: .running), run(2, minutesAgo: 5, status: .succeeded)]) == .running)
    }

    @Test func theLastFinishedBuildDecidesTheColour() {
        #expect(badge([run(1, minutesAgo: 20, status: .succeeded), run(2, minutesAgo: 8, status: .failed)]) == .failed)
        #expect(badge([run(1, minutesAgo: 20, status: .failed), run(2, minutesAgo: 8, status: .succeeded)]) == .succeeded)
        #expect(badge([run(2, minutesAgo: 8, status: .errored)]) == .failed)
    }

    @Test func theLastBuildKeepsItsDotHoweverOldItIs() {
        #expect(badge([run(1, minutesAgo: 16, status: .failed, ranFor: 5)]) == .failed)
        #expect(badge([run(1, minutesAgo: 3 * 24 * 60, status: .succeeded)]) == .succeeded)
    }

    @Test func aCancelledSkippedOrUnknownBuildGetsAGreyDot() {
        #expect(badge([run(1, minutesAgo: 6, status: .canceled)]) == .stopped)
        #expect(badge([run(1, minutesAgo: 6, status: .skipped)]) == .stopped)
        #expect(badge([run(1, minutesAgo: 6, status: nil)]) == .stopped)
    }

    @Test func noBuildMeansNoDot() {
        #expect(badge([]) == nil)
    }

    @Test func theLastBuildIsTheNewestNotTheHighestInTheList() {
        #expect(badge([run(5, minutesAgo: 9, status: .succeeded), run(9, minutesAgo: 2, status: .failed), run(7, minutesAgo: 6, status: .succeeded)]) == .failed)
    }

    @Test func colorsAreTheSystemOnes() {
        #expect(MenuBarBadge.running.color == .systemBlue)
        #expect(MenuBarBadge.failed.color == .systemRed)
        #expect(MenuBarBadge.succeeded.color == .systemGreen)
        #expect(MenuBarBadge.stopped.color == .systemGray)
    }

    @Test func voiceOverHearsTheStateNotJustTheIcon() {
        #expect(MenuBarBadge.accessibilityLabel(for: nil) == "Cumulus")
        #expect(MenuBarBadge.accessibilityLabel(for: .running).contains("running"))
        #expect(MenuBarBadge.accessibilityLabel(for: .failed).contains("failed"))
        #expect(MenuBarBadge.accessibilityLabel(for: .succeeded).contains("succeeded"))
    }

    @Test func theCloudSymbolIsDrawnWithinItsImage() throws {
        let cloud = try #require(NSImage(systemSymbolName: "cloud", accessibilityDescription: nil))
        let bounds = cloud.drawnBounds

        #expect(bounds.width > 10 && bounds.height > 8)
        #expect(bounds.minX >= 0 && bounds.minY >= 0)
        #expect(bounds.maxX <= cloud.size.width + 0.5 && bounds.maxY <= cloud.size.height + 0.5)
    }
}
