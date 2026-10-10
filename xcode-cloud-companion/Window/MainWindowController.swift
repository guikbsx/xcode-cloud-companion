import AppKit
import SwiftUI

/// The main window: an `NSWindow` hosting SwiftUI, like Settings. A SwiftUI `Window` scene cannot be opened from an `NSMenu` item.
final class MainWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "MainWindow"

    private let buildStore: BuildStore
    private let usageStore: UsageStore
    private let settings: SettingsModel
    private let pins = PinnedWorkflows()
    private lazy var workflowStore = WorkflowDetailStore(client: { [buildStore] in await buildStore.detailClient() })
    private lazy var artifactSaver = ArtifactSaver(client: { [buildStore] in await buildStore.detailClient() })
    private lazy var launcher = BuildLauncher(client: { [buildStore] in await buildStore.detailClient() })
    private let icons = AppIconStore()
    private lazy var logOpener = LogOpener(client: { [buildStore] in await buildStore.detailClient() })
    private lazy var workflowTests = WorkflowTestsModel(
        snapshot: { [buildStore] in buildStore.snapshot },
        loadTests: { [weak self] run, actions in
            guard let self else { return nil }
            await extrasStore.loadTests(for: run, actions: actions)
            if case .failed(let message, _, _) = extrasStore.state(.tests, runID: run.id) { return message }
            return nil
        },
        budget: { [buildStore] in
            await buildStore.updateRateLimit()
            return buildStore.rateLimit
        }
    )
    private lazy var pauser = WorkflowPauser(
        client: { [buildStore] in await buildStore.detailClient() },
        applied: { [weak self] workflowID, isEnabled in
            guard let self else { return }
            await workflowStore.setEnabled(isEnabled, workflowID: workflowID)
            await buildStore.setWorkflowEnabled(isEnabled, workflowID: workflowID)
        }
    )
    private lazy var extrasStore = BuildExtrasStore(client: { [buildStore] in await buildStore.detailClient() })
    private let navigation: NavigationModel
    private let activation: ActivationPolicyCoordinator
    private let openSettings: () -> Void
    private var window: NSWindow?

    init(buildStore: BuildStore, usageStore: UsageStore, settings: SettingsModel, navigation: NavigationModel, activation: ActivationPolicyCoordinator, openSettings: @escaping () -> Void) {
        self.buildStore = buildStore
        self.usageStore = usageStore
        self.settings = settings
        self.navigation = navigation
        self.activation = activation
        self.openSettings = openSettings
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        activation.windowWillShow()
        window.makeKeyAndOrderFront(nil)
        buildStore.windowDidOpen()
        Task { await buildStore.loadCacheIfNeeded() }
    }

    func windowWillClose(_ notification: Notification) {
        activation.windowDidClose()
        buildStore.windowDidClose()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView(
            buildStore: buildStore, usageStore: usageStore, settings: settings, extrasStore: extrasStore, workflowStore: workflowStore, artifactSaver: artifactSaver, launcher: launcher, icons: icons, logOpener: logOpener, workflowTests: workflowTests, pauser: pauser, navigation: navigation, pins: pins, openSettings: openSettings
        ))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Cumulus"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 560)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}
