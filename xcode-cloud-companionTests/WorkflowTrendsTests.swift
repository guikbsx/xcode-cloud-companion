import Foundation
import SwiftUI
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct WorkflowTrendsTests {
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    /// A finished build `index` hours ago that waited `wait` seconds and ran `minutes`.
    private func run(_ index: Int, minutes: Double, wait: TimeInterval = 60, status: CICompletionStatus? = .succeeded, progress: CIExecutionProgress = .complete, started: Bool = true) -> CIBuildRun {
        let created = now.addingTimeInterval(-Double(index) * 3600)
        return CIBuildRun(
            id: "r\(index)", productID: "p", number: 1000 - index, createdDate: created,
            startedDate: started ? created.addingTimeInterval(wait) : nil,
            finishedDate: started && progress == .complete ? created.addingTimeInterval(wait + minutes * 60) : nil,
            executionProgress: progress, completionStatus: progress == .complete ? status : nil, startReason: nil, workflowID: "w", workflowName: nil, sourceBranchOrTag: nil
        )
    }

    @Test func medianIsTheMiddleValueOrTheMeanOfTheTwoMiddleOnes() {
        #expect(WorkflowTrends.median([]) == nil)
        #expect(WorkflowTrends.median([7]) == 7)
        #expect(WorkflowTrends.median([3, 1, 2]) == 2)
        #expect(WorkflowTrends.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func theFiguresComeFromFinishedBuildsOnlyNewestThirty() {
        var runs = (0..<40).map { run($0, minutes: 10) }
        runs.append(run(100, minutes: 1, status: nil, progress: .running))
        runs.append(run(101, minutes: 1, status: .canceled))

        let trends = WorkflowTrends(runs: runs)

        #expect(trends.sampleSize == WorkflowTrends.sampleLimit)
        #expect(trends.medianDuration == 600 && trends.medianQueueWait == 60 && trends.successRate == 1)
        #expect(trends.bars.count == 30 && trends.bars.first?.id == "r29" && trends.bars.last?.id == "r0", "oldest first")
    }

    @Test func aDriftComparesTheNewestTenWithTheOnesBefore() {
        let slower = (0..<10).map { run($0, minutes: 12) } + (10..<30).map { run($0, minutes: 10) }
        let steady = (0..<30).map { run($0, minutes: 10 + Double($0 % 2)) }
        let failing = (0..<10).map { run($0, minutes: 10, status: $0 < 5 ? .failed : .succeeded) } + (10..<30).map { run($0, minutes: 10) }

        let slow = WorkflowTrends(runs: slower)
        #expect(slow.durationDrift == .change(0.2) && slow.queueDrift == .stable)
        #expect(WorkflowTrends(runs: steady).durationDrift == .stable)
        guard case .change(let fraction)? = WorkflowTrends(runs: failing).successDrift else {
            Issue.record("expected a drop in the success rate")
            return
        }
        #expect(fraction == -0.5)
    }

    @Test func fewBuildsGiveFiguresButNoDrift() {
        let five = WorkflowTrends(runs: (0..<5).map { run($0, minutes: 10) })
        let six = WorkflowTrends(runs: (0..<6).map { run($0, minutes: $0 < 3 ? 20 : 10) })

        #expect(five.sampleSize == 5 && five.medianDuration == 600 && five.durationDrift == nil)
        #expect(six.durationDrift == .change(1), "three newest against the three before")
        #expect(WorkflowTrends(runs: []).sampleSize == 0 && WorkflowTrends(runs: []).successRate == nil)
    }

    @Test func aBuildThatNeverStartedCountsForTheRateButNotForTheTimes() {
        let runs = [run(0, minutes: 10, status: .failed, started: false), run(1, minutes: 10)]

        let trends = WorkflowTrends(runs: runs)

        #expect(trends.sampleSize == 2 && trends.successRate == 0.5)
        #expect(trends.medianDuration == 600 && trends.bars.map(\.id) == ["r1"])
    }

    @Test func theSectionWordsADriftAndTintsTheBadDirection() {
        #expect(WorkflowTrendsSection.driftText(nil, sampleSize: 3) == "Not enough builds to compare yet")
        #expect(WorkflowTrendsSection.driftText(.stable, sampleSize: 30) == "Stable")
        #expect(WorkflowTrendsSection.driftText(.change(0.18), sampleSize: 30) == "+18% over the newest 10")
        #expect(WorkflowTrendsSection.driftTint(.change(0.2), lowerIsBetter: true) == BuildStatus.errored.tint)
        #expect(WorkflowTrendsSection.driftTint(.change(-0.2), lowerIsBetter: true) == BuildStatus.succeeded.tint)
        #expect(WorkflowTrendsSection.driftTint(.change(-0.2), lowerIsBetter: false) == BuildStatus.errored.tint)
        #expect(WorkflowTrendsSection.driftTint(.stable, lowerIsBetter: false) == .secondary)
    }
}
