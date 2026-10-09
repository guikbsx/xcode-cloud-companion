import AppKit
import Testing
@testable import XcodeCloudCompanion

@MainActor
struct StatusMenuTests {
    private final class Target: NSObject {
        @objc func openSettings() {}
    }

    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private var summary: UsageSummary {
        let plan = UsagePlan(hours: 25, resetAnchor: now.addingTimeInterval(20 * 86_400))
        return UsageCalculator.summary(snapshot: .empty, ledger: UsageLedger(), plan: plan, now: now)
    }

    private func state(needsAPIKey: Bool = false, summary: UsageSummary? = nil, isSyncing: Bool = false, error: String? = nil) -> StatusMenuState {
        StatusMenuState(needsAPIKey: needsAPIKey, summary: summary, lastSync: now.addingTimeInterval(-120), isSyncing: isSyncing, errorMessage: error, now: now)
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.filter { !$0.isSeparatorItem && $0.view == nil }.map(\.title)
    }

    @Test func usageBlocksAndCommandsAreThere() {
        let items = StatusMenuBuilder.items(for: state(summary: summary), actions: StatusMenuActions())

        #expect(items.filter { $0.view != nil }.count == 3)
        #expect(titles(items).contains("Refresh"))
        #expect(titles(items).contains("Update from App Store Connect"))
        #expect(titles(items).contains("Import Usage Export…"))
        #expect(items.first { $0.title == "Refresh" }?.keyEquivalent == "r")
        #expect(items.first { $0.title == "Settings…" }?.keyEquivalent == ",")
        #expect(items.last?.action == #selector(NSApplication.terminate(_:)))
        #expect(items.last?.keyEquivalent == "q")
    }

    @Test func withoutAKeyTheMenuLeadsToSettings() {
        var opened = false
        let items = StatusMenuBuilder.items(for: state(needsAPIKey: true), actions: StatusMenuActions(openSettings: { opened = true }))

        let first = items.first
        #expect(first?.title == "Set Up Your App Store Connect API Key…")
        (first?.target as? MenuActionTarget)?.run(first)
        #expect(opened)
        #expect(titles(items).contains("Set Your Plan’s Reset Date…"))
    }

    @Test func anErrorIsShownWithoutHidingTheFigures() {
        let items = StatusMenuBuilder.items(for: state(summary: summary, error: "No internet connection."), actions: StatusMenuActions())

        #expect(items.filter { $0.view != nil }.count == 3)
        #expect(titles(items).contains("No internet connection."))
    }

    @Test func whileSyncingRefreshWaits() {
        let items = StatusMenuBuilder.items(for: state(summary: summary, isSyncing: true), actions: StatusMenuActions())

        #expect(titles(items).contains("Updating…"))
        #expect(items.first { $0.title == "Refresh" }?.isEnabled == false)
    }

    @Test func theDiagnosticOnlyAppearsWhenProvided() {
        let without = StatusMenuBuilder.items(for: state(summary: summary), actions: StatusMenuActions())
        let with = StatusMenuBuilder.items(for: state(summary: summary), actions: StatusMenuActions(openDiagnostic: {}))

        #expect(!titles(without).contains("Usage Diagnostic…"))
        #expect(titles(with).contains("Usage Diagnostic…"))
    }

    @Test func theMenuBarShowsThePercentageUsed() {
        #expect(StatusMenuBuilder.buttonTitle(for: summary) == UsageFormat.percent(0))
        #expect(StatusMenuBuilder.buttonTitle(for: nil) == "")
    }

    @Test func mainMenuKeepsCopyAndPasteWorkingInTextFields() {
        let target = Target()
        let menu = MainMenu.make(settingsTarget: target, settingsAction: #selector(Target.openSettings))

        let editItems = menu.items.compactMap(\.submenu).flatMap(\.items)
        #expect(editItems.contains { $0.action == #selector(NSText.paste(_:)) && $0.keyEquivalent == "v" })
        #expect(editItems.contains { $0.action == #selector(NSText.copy(_:)) && $0.keyEquivalent == "c" })
        #expect(editItems.contains { $0.action == #selector(Target.openSettings) && $0.keyEquivalent == "," })
    }

    @Test func appStaysOutOfTheDock() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }
}
