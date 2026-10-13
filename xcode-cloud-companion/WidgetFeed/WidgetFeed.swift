import Foundation
import WidgetKit

nonisolated extension AppSwatch {
    /// A colour the widget extension can draw without the app: it has neither the palette nor AppKit's system colours
    /// as the app resolves them, so the system hues go by their light values.
    var widgetTint: WidgetSnapshot.Tint {
        func tint(_ red: Double, _ green: Double, _ blue: Double) -> WidgetSnapshot.Tint {
            WidgetSnapshot.Tint(red: red / 255, green: green / 255, blue: blue / 255)
        }
        return switch self {
        case .blue: tint(0, 122, 255)
        case .cyan: tint(50, 173, 230)
        case .yellow: tint(255, 204, 0)
        case .purple: tint(175, 82, 222)
        case .orange: tint(255, 149, 0)
        case .mint: tint(0, 199, 190)
        case .gray: tint(142, 142, 147)
        case .icon(let color): WidgetSnapshot.Tint(red: color.red, green: color.green, blue: color.blue)
        }
    }
}

/// What the widgets draw, made from what the app shows for the account on screen: the same builds, the same figure
/// for the cycle, the same colours.
nonisolated enum WidgetFeed {
    static let newestBuilds = 10

    static func snapshot(of builds: BuildSnapshot, summary: UsageSummary?, palette: AppPalette, now: Date) -> WidgetSnapshot {
        let products = Dictionary(builds.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newestFirst = builds.runs.sorted { ($0.createdDate ?? .distantPast, $0.id) > ($1.createdDate ?? .distantPast, $1.id) }
        // The newest of every app, so that a widget set on one app always has its build, then the newest of all.
        var kept = Set(newestFirst.prefix(newestBuilds).map(\.id))
        var seenProducts: Set<String> = []
        for run in newestFirst where seenProducts.insert(run.productID).inserted {
            kept.insert(run.id)
        }
        return WidgetSnapshot(
            generatedAt: now,
            hasAccount: true,
            apps: builds.products.map { WidgetSnapshot.App(id: $0.id, name: $0.displayName, tint: palette.swatch(for: $0.name).widgetTint) },
            builds: newestFirst.filter { kept.contains($0.id) }.compactMap { run in
                guard let product = products[run.productID] else { return nil }
                return build(run, product: product, palette: palette)
            },
            cycle: summary.map { cycle($0, displayNames: builds.displayNames, palette: palette) }
        )
    }

    private static func build(_ run: CIBuildRun, product: CIProduct, palette: AppPalette) -> WidgetSnapshot.Build {
        let status = BuildStatus(run: run)
        let isRunning = status == .running
        return WidgetSnapshot.Build(
            id: run.id,
            appID: product.id,
            app: product.displayName,
            number: run.number,
            workflow: run.workflowName,
            state: state(status),
            failedTests: run.issueCounts?.testFailures.flatMap { $0 > 0 ? $0 : nil },
            date: isRunning ? run.startedDate ?? run.createdDate : run.finishedDate ?? run.startedDate ?? run.createdDate,
            durationSeconds: isRunning ? nil : run.startedDate.flatMap { started in run.finishedDate.map { Int($0.timeIntervalSince(started).rounded()) } },
            tint: palette.swatch(for: product.name).widgetTint
        )
    }

    private static func state(_ status: BuildStatus) -> WidgetSnapshot.BuildState {
        switch status {
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .errored: .errored
        case .canceled: .canceled
        case .skipped: .skipped
        case .finished: .finished
        }
    }

    private static func cycle(_ summary: UsageSummary, displayNames: [String: String], palette: AppPalette) -> WidgetSnapshot.Cycle {
        WidgetSnapshot.Cycle(
            usedMinutes: summary.usedMinutes,
            quotaMinutes: summary.quotaMinutes,
            percentUsed: Int((summary.writtenFractionUsed * 100).rounded()),
            isEstimate: summary.estimatedMinutes > 0,
            isMeasuring: summary.measurement.isMeasuring,
            resetDate: summary.resetDate,
            segments: summary.byApp.filter { $0.totalMinutes > 0 }.map {
                WidgetSnapshot.Segment(app: displayNames[$0.product] ?? $0.product, minutes: $0.totalMinutes, tint: palette.swatch(for: $0.product).widgetTint)
            }
        )
    }
}

/// Keeps the widgets' file in step with the account on screen, and tells the widgets when what they show changed.
final class WidgetFeedWriter {
    private let store: WidgetSnapshotStore
    private let reload: () -> Void
    private var lastWritten: WidgetSnapshot?

    init(
        store: WidgetSnapshotStore = WidgetSnapshotStore(directory: SharedContainer.applicationSupport),
        reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store
        self.reload = reload
    }

    /// `session` is the account on screen; without one the widgets only show the way into the app.
    func update(for session: AccountSession?, now: Date = Date()) async {
        let snapshot: WidgetSnapshot
        if let session {
            let builds = session.buildStore.snapshot
            let summary = session.usageSummary(now: now)
            snapshot = WidgetFeed.snapshot(of: builds, summary: summary, palette: session.palette(for: builds, summary: summary), now: now)
        } else {
            snapshot = .empty(at: now)
        }
        // A sync that changed nothing does not wake the widgets.
        if let lastWritten, lastWritten.hasSameContent(as: snapshot) { return }
        guard await Self.save(snapshot, to: store) else { return }
        lastWritten = snapshot
        reload()
    }

    @concurrent private static func save(_ snapshot: WidgetSnapshot, to store: WidgetSnapshotStore) async -> Bool {
        store.save(snapshot)
    }
}
