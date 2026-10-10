import AppKit

/// The “Apps” section: one row per app with its cycle usage, and a submenu of its latest builds.
enum AppBuildsMenu {
    static let buildsPerApp = 10

    static func items(
        snapshot: BuildSnapshot,
        summary: UsageSummary?,
        palette: AppPalette = AppPalette(),
        now: Date,
        open: @escaping (String) -> Void
    ) -> [NSMenuItem] {
        let runsByProduct = Dictionary(grouping: snapshot.runs, by: \.productID)
        let products = snapshot.products
            .filter { runsByProduct[$0.id]?.isEmpty == false }
            .sorted { latestCreation(runsByProduct[$0.id]) > latestCreation(runsByProduct[$1.id]) }
        guard !products.isEmpty else { return [] }

        var items: [NSMenuItem] = [.sectionHeader(title: String(localized: "Apps · this cycle"))]
        for product in products {
            let runs = (runsByProduct[product.id] ?? []).sorted { ($0.number ?? 0) > ($1.number ?? 0) }
            let item = NSMenuItem(title: product.name, action: nil, keyEquivalent: "")
            if let latest = runs.first {
                item.attributedTitle = BuildStatusDot.title(product.name, status: BuildStatus(run: latest), appSwatch: palette.swatch(for: product.name))
            }
            let measuring = summary?.measurement.isMeasuring == true
            if let usage = summary?.byApp.first(where: { $0.product == product.name }), usage.totalMinutes > 0 {
                let minutes = UsageFormat.compactMinutes(usage.totalMinutes)
                item.badge = NSMenuItemBadge(string: measuring
                    ? String(localized: "\(minutes)…", comment: "An app's minutes while its builds are still being measured")
                    : minutes)
            } else if measuring {
                item.badge = NSMenuItemBadge(string: "…")
            }
            if let building = runs.first(where: { BuildStatus(run: $0) == .running }) {
                item.subtitle = building.number.map { String(localized: "Building now · #\($0)") } ?? String(localized: "Building now")
            }
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for run in runs.prefix(buildsPerApp) {
                submenu.addItem(buildItem(run, product: product, actions: snapshot.actionsByRunID[run.id] ?? [], now: now, open: open))
            }
            item.submenu = submenu
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    static func buildItem(
        _ run: CIBuildRun, product: CIProduct, actions: [CIBuildAction], now: Date, open: @escaping (String) -> Void
    ) -> NSMenuItem {
        let number = run.number.map { "#\($0)" } ?? "#?"
        let title = UsageFormat.dotted([number, run.workflowName].compactMap(\.self))
        let item = NSMenuItem.action(title) { open(run.id) }
        item.attributedTitle = BuildStatusDot.title(title, status: BuildStatus(run: run))
        item.subtitle = subtitle(for: run, actions: actions, now: now)
        item.toolTip = BuildStatus(run: run).label
        return item
    }

    static func subtitle(for run: CIBuildRun, actions: [CIBuildAction], now: Date) -> String {
        var parts = [BuildStatus(run: run).label]
        if let started = run.startedDate {
            parts.append(UsageFormat.minutes(UsageEstimator.duration(from: started, to: run.finishedDate, now: now) / 60))
        }
        if let created = run.createdDate {
            parts.append(UsageFormat.relative(created, now: now))
        }
        if let branch = run.sourceBranchOrTag {
            parts.append(branch)
        }
        return UsageFormat.dotted(parts)
    }

    private static func latestCreation(_ runs: [CIBuildRun]?) -> Date {
        runs?.compactMap(\.createdDate).max() ?? .distantPast
    }
}
