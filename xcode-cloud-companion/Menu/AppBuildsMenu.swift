import AppKit

/// The “Apps” section: one row per app with its cycle usage, and a submenu of its latest builds.
enum AppBuildsMenu {
    static let buildsPerApp = 10

    static func items(snapshot: BuildSnapshot, summary: UsageSummary?, now: Date, open: @escaping (URL) -> Void) -> [NSMenuItem] {
        let runsByProduct = Dictionary(grouping: snapshot.runs, by: \.productID)
        let products = snapshot.products
            .filter { runsByProduct[$0.id]?.isEmpty == false }
            .sorted { latestCreation(runsByProduct[$0.id]) > latestCreation(runsByProduct[$1.id]) }
        guard !products.isEmpty else { return [] }

        var items: [NSMenuItem] = [.sectionHeader(title: String(localized: "Apps"))]
        for product in products {
            let runs = (runsByProduct[product.id] ?? []).sorted { ($0.number ?? 0) > ($1.number ?? 0) }
            let item = NSMenuItem(title: product.name, action: nil, keyEquivalent: "")
            item.image = runs.first.flatMap { statusImage(for: $0) }
            if let usage = summary?.byApp.first(where: { $0.product == product.name }), usage.totalMinutes > 0 {
                item.badge = NSMenuItemBadge(string: UsageFormat.minutes(usage.totalMinutes))
            }
            if runs.contains(where: { $0.executionProgress != .complete }) {
                item.subtitle = String(localized: "Building now")
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

    static func buildItem(_ run: CIBuildRun, product: CIProduct, actions: [CIBuildAction], now: Date, open: @escaping (URL) -> Void) -> NSMenuItem {
        let number = run.number.map { "#\($0)" } ?? "#?"
        let title = [number, run.workflowName].compactMap(\.self).joined(separator: " · ")
        let url = AppStoreConnectLinks.build(appID: product.appID, buildRunID: run.id)
        let item = NSMenuItem.action(title) { open(url) }
        item.image = statusImage(for: run)
        item.subtitle = subtitle(for: run, actions: actions, now: now)
        item.toolTip = url.absoluteString
        return item
    }

    static func subtitle(for run: CIBuildRun, actions: [CIBuildAction], now: Date) -> String {
        var parts = [statusText(for: run)]
        if let started = run.startedDate {
            parts.append(UsageFormat.minutes(UsageEstimator.duration(from: started, to: run.finishedDate, now: now) / 60))
        }
        if let created = run.createdDate {
            parts.append(UsageFormat.relative(created, now: now))
        }
        if let branch = run.sourceBranchOrTag {
            parts.append(branch)
        }
        return parts.joined(separator: " · ")
    }

    static func statusText(for run: CIBuildRun) -> String {
        switch (run.executionProgress, run.completionStatus) {
        case (.pending, _): String(localized: "Waiting")
        case (.running, _): String(localized: "Running")
        case (_, .succeeded?): String(localized: "Succeeded")
        case (_, .failed?): String(localized: "Failed")
        case (_, .errored?): String(localized: "Error")
        case (_, .canceled?): String(localized: "Canceled")
        case (_, .skipped?): String(localized: "Skipped")
        default: String(localized: "Finished")
        }
    }

    static func statusSymbol(for run: CIBuildRun) -> (name: String, color: NSColor) {
        switch (run.executionProgress, run.completionStatus) {
        case (.pending, _), (.running, _): ("arrow.triangle.2.circlepath", .systemBlue)
        case (_, .succeeded?): ("checkmark.circle.fill", .systemGreen)
        case (_, .failed?): ("xmark.circle.fill", .systemRed)
        case (_, .errored?): ("exclamationmark.triangle.fill", .systemOrange)
        default: ("minus.circle.fill", .secondaryLabelColor)
        }
    }

    private static func statusImage(for run: CIBuildRun) -> NSImage? {
        let symbol = statusSymbol(for: run)
        return NSImage(systemSymbolName: symbol.name, accessibilityDescription: statusText(for: run))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [symbol.color]))
    }

    private static func latestCreation(_ runs: [CIBuildRun]?) -> Date {
        runs?.compactMap(\.createdDate).max() ?? .distantPast
    }
}
