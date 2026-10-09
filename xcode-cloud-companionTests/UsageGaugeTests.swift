import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AppPaletteTests {
    @Test func theBiggestConsumerGetsTheFirstColourAndAppsKeepTheirs() {
        var palette = AppPalette()
        let firstChanged = palette.update(ranking: ["big", "medium", "small"])

        #expect(firstChanged)
        #expect(palette.swatch(for: "big") == .blue)
        #expect(palette.swatch(for: "medium") == .cyan)
        #expect(palette.swatch(for: "small") == .yellow)

        // The ranking changes: nobody changes colour, and a newcomer takes the next free one.
        let secondChanged = palette.update(ranking: ["small", "newcomer", "big", "medium"])
        #expect(secondChanged)
        #expect(palette.swatch(for: "big") == .blue)
        #expect(palette.swatch(for: "small") == .yellow)
        #expect(palette.swatch(for: "newcomer") == .purple)
    }

    @Test func aColourIsGivenBackWhenItsAppDisappears() {
        var palette = AppPalette()
        palette.update(ranking: ["a", "b", "c"])

        palette.update(ranking: ["a", "c"])
        palette.update(ranking: ["a", "c", "d"])

        #expect(palette.swatch(for: "a") == .blue)
        #expect(palette.swatch(for: "c") == .yellow)
        #expect(palette.swatch(for: "d") == .cyan)
    }

    @Test func beyondSixAppsTheRestIsGrayAndAnUnchangedPaletteReportsNoChange() {
        var palette = AppPalette()
        let apps = (1...8).map { "app\($0)" }

        palette.update(ranking: apps)

        #expect(Set(apps.prefix(6).map(palette.swatch(for:))).count == 6)
        #expect(palette.swatch(for: "app7") == .gray)
        #expect(palette.swatch(for: "app8") == .gray)
        #expect(palette.swatch(for: "unknown") == .gray)
        let changedAgain = palette.update(ranking: apps)
        #expect(!changedAgain)
    }

    @Test func rankingPutsConsumersFirstThenIdleAppsByNameAndIgnoresUnknownOnes() {
        let ranking = AppPalette.ranking(byConsumption: ["b", "ghost", "a"], allApps: ["c", "a", "b", "d"])

        #expect(ranking == ["b", "a", "c", "d"])
    }

    @Test func assignmentsSurviveARelaunch() throws {
        let suite = "AppPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var palette = AppPalette()
        palette.update(ranking: ["a", "b"])

        AppPaletteStore().save(palette, to: defaults)

        #expect(AppPaletteStore().load(from: defaults) == palette)
    }

    @Test func nothingSavedMeansAnEmptyPalette() throws {
        let suite = "AppPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppPaletteStore().load(from: defaults) == AppPalette())
    }
}

struct GaugeSegmentsTests {
    private func summary(byApp: [AppUsage], estimated: Double = 0) -> UsageSummary {
        let plan = UsagePlan(hours: 25, resetAnchor: Date(timeIntervalSince1970: 1_794_000_000))
        return UsageSummary(
            plan: plan, cycle: DateInterval(start: Date(timeIntervalSince1970: 1_791_400_000), end: Date(timeIntervalSince1970: 1_794_000_000)),
            now: Date(timeIntervalSince1970: 1_791_600_000), billedMinutes: byApp.reduce(0) { $0 + $1.billedMinutes }, estimatedMinutes: estimated,
            estimatedBuildCount: estimated > 0 ? 2 : 0, lastImport: nil, daily: [], buildsLast30Days: 0, byApp: byApp
        )
    }

    @Test func oneSegmentPerBilledAppBiggestFirstThenTheEstimatedOne() {
        let summary = summary(byApp: [
            AppUsage(product: "small", billedMinutes: 14),
            AppUsage(product: "big", billedMinutes: 410, estimatedMinutes: 30),
            AppUsage(product: "medium", billedMinutes: 38),
        ], estimated: 30)

        #expect(summary.gaugeSegments == [
            GaugeSegment(product: "big", minutes: 410),
            GaugeSegment(product: "medium", minutes: 38),
            GaugeSegment(product: "small", minutes: 14),
            GaugeSegment(product: nil, minutes: 30),
        ])
    }

    @Test func appsWithoutBilledMinutesAndAbsentEstimatesLeaveNoSegment() {
        let summary = summary(byApp: [
            AppUsage(product: "estimatedOnly", billedMinutes: 0, estimatedMinutes: 12),
            AppUsage(product: "billed", billedMinutes: 20),
        ])

        #expect(summary.gaugeSegments == [GaugeSegment(product: "billed", minutes: 20)])
    }

    @Test func equalAppsAreOrderedByNameSoTheBarNeverFlickers() {
        let summary = summary(byApp: [AppUsage(product: "b", billedMinutes: 10), AppUsage(product: "a", billedMinutes: 10)])

        #expect(summary.gaugeSegments.map(\.product) == ["a", "b"])
    }

    @Test func widthsAreProportionalToTheQuota() {
        let widths = GaugeLayout.widths(minutes: [750, 150], quotaMinutes: 1500, totalWidth: 272)

        #expect(abs(widths[0] - 136) < 0.0001)
        #expect(abs(widths[1] - 27.2) < 0.0001)
    }

    @Test func aTinySliceStaysVisibleWithoutOverflowing() {
        let widths = GaugeLayout.widths(minutes: [1400, 1, 0], quotaMinutes: 1500, totalWidth: 272)

        #expect(widths[1] == 2)
        #expect(widths[2] == 0)
        #expect(widths.reduce(0, +) <= 272.0001)
    }

    @Test func overQuotaTheSlicesShrinkToTheBarButKeepTheirMinimum() {
        let widths = GaugeLayout.widths(minutes: [1200, 600, 1], quotaMinutes: 1500, totalWidth: 272)

        #expect(abs(widths.reduce(0, +) - 272) < 0.0001)
        #expect(widths[2] == 2)
        #expect(widths[0] > widths[1])
    }

    @Test func noQuotaOrNoWidthMeansNothingToDraw() {
        #expect(GaugeLayout.widths(minutes: [10], quotaMinutes: 0, totalWidth: 272) == [0])
        #expect(GaugeLayout.widths(minutes: [10], quotaMinutes: 1500, totalWidth: 0) == [0])
    }
}
