import Foundation
import Testing
@testable import XcodeCloudCompanion

struct SyncActivityTests {
    private let lastSync = Date(timeIntervalSince1970: 1_791_547_200)
    private let measuring = MeasurementProgress(totalActions: 40, measuredActions: 4)
    private let measured = MeasurementProgress(totalActions: 40, measuredActions: 40)

    private func activity(
        syncing: Bool = false, step: String? = nil, lastSync: Date? = Date(timeIntervalSince1970: 1_791_547_200), error: String? = nil,
        measurement: MeasurementProgress? = nil
    ) -> SyncActivity {
        .current(isSyncing: syncing, activity: step, lastSync: lastSync, errorMessage: error, measurement: measurement)
    }

    @Test func atRestItSaysSinceWhenAndASyncSaysWhatItDoes() {
        #expect(activity() == .idle(lastSync: lastSync))
        #expect(activity(lastSync: nil) == .idle(lastSync: nil))
        #expect(activity(syncing: true, step: "Listing builds of Alpha…", measurement: measured) == .syncing(activity: "Listing builds of Alpha…"))
    }

    @Test func anErrorShowsUntilTheNextSyncStarts() {
        #expect(activity(error: "No internet connection.") == .failed(message: "No internet connection."))
        #expect(activity(syncing: true, error: "No internet connection.") == .syncing(activity: nil))
    }

    @Test func theFirstSyncAndTheMeasureComeBeforeEverythingElse() {
        // Nothing read yet: there is nothing to count, only a step to name.
        #expect(activity(syncing: true, step: "Listing apps…", lastSync: nil) == .measuring(MeasurementProgress(), isFirstSync: true, activity: "Listing apps…"))
        // Between two passes no sync runs, and the builds are still being measured.
        #expect(activity(measurement: measuring) == .measuring(measuring, isFirstSync: false, activity: nil))
        #expect(activity(error: "Apple’s hourly request limit is reached.", measurement: measuring) == .measuring(measuring, isFirstSync: false, activity: nil))
    }

    @MainActor @Test func aSyncNewerThanTheClockLastReadIsNeverSaidToBeInTheFuture() {
        let behind = lastSync.addingTimeInterval(-35)

        #expect(SyncActivityView.updatedText(lastSync: lastSync, now: behind) == SyncActivityView.updatedText(lastSync: lastSync, now: lastSync))
        #expect(!SyncActivityView.updatedText(lastSync: lastSync, now: behind).contains("in 35"))
        #expect(SyncActivityView.updatedText(lastSync: lastSync, now: lastSync.addingTimeInterval(120)).contains("2 minutes ago"))
        #expect(SyncActivityView.updatedText(lastSync: nil, now: lastSync) == "Not updated yet")
    }

    @Test func onlyTheMeasureTakesRoomInTheSidebar() {
        #expect(activity(measurement: measuring).isCard)
        #expect(!activity().isCard && !activity(syncing: true).isCard && !activity(error: "x").isCard)
    }
}

struct WindowContentStateTests {
    private func state(
        configured: Bool = true, attempted: Bool = true, syncing: Bool = false, content: Bool = false, others: Bool = false,
        error: String? = nil, step: String? = nil
    ) -> WindowContentState {
        .of(
            isConfigured: configured, hasAttemptedSync: attempted, isSyncing: syncing, hasContent: content, anotherAccountHasContent: others,
            errorMessage: error, step: step
        )
    }

    @Test func theVeryFirstFetchSaysWhatItReadsUntilSomethingArrives() {
        // Before the first sync has even looked for the key, nothing says the app is not set up.
        #expect(state(configured: false, attempted: false) == .loading(step: nil))
        #expect(state(syncing: true, step: "Listing builds of Alpha…") == .loading(step: "Listing builds of Alpha…"))
        #expect(state(content: true) == .ready)
        // Later syncs never bring the screen back.
        #expect(state(syncing: true, content: true, step: "Listing apps…") == .ready)
    }

    @Test func aFirstFetchThatFailsSaysWhyAndKeepsSayingItWhileItTriesAgain() {
        #expect(state(error: "No internet connection.") == .failed(message: "No internet connection.", isRetrying: false))
        #expect(state(syncing: true, error: "No internet connection.") == .failed(message: "No internet connection.", isRetrying: true))
        #expect(state(content: true, error: "No internet connection.") == .ready)
    }

    @Test func onlyAKeyKnownToBeMissingSaysTheAppIsNotSetUp() {
        #expect(state(configured: false) == .notSetUp)
        #expect(state(configured: false, content: true) == .notSetUp)
        #expect(state(configured: false, syncing: true) == .loading(step: nil))
    }

    @Test func aNewAccountsFirstFetchDoesNotHideTheWindowOnceAnotherAccountHasBuilds() {
        #expect(state(syncing: true, others: true, step: "Listing apps…") == .ready)
        #expect(state(others: true, error: "No internet connection.") == .ready)
        // A missing key is still said, whatever the other accounts hold.
        #expect(state(configured: false, others: true) == .notSetUp)
    }

    @Test func anotherAccountsFirstFetchOrMeasureShowsNextToTheAccountOnScreen() {
        let measuring = SyncActivity.measuring(MeasurementProgress(totalActions: 40, measuredActions: 4), isFirstSync: false, activity: nil)
        let first = SyncActivity.measuring(MeasurementProgress(), isFirstSync: true, activity: "Listing apps…")
        let idle = SyncActivity.idle(lastSync: nil)

        #expect(SyncActivity.background(among: [("Personal", idle), ("Work", .syncing(activity: nil))]) == nil)
        #expect(SyncActivity.background(among: [])?.name == nil)
        let shown = SyncActivity.background(among: [("Personal", idle), ("Work", first), ("Client", measuring)])
        #expect(shown?.name == "Work" && shown?.activity == first)
    }
}
