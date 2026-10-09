import AppKit

/// The top of the menu: the latest builds across every app, one line each, a coloured dot telling how they went.
enum LatestBuildsMenu {
    static let buildCount = 5
    /// Width left to the app name before the build, so the numbers line up in a column.
    static let appColumnWidth: CGFloat = 120
    static let maximumAppNameLength = 14

    static func items(snapshot: BuildSnapshot, now: Date, open: @escaping (URL) -> Void) -> [NSMenuItem] {
        let products = Dictionary(snapshot.products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = snapshot.runs
            .filter { $0.createdDate != nil }
            .sorted { ($0.createdDate ?? .distantPast, $0.number ?? 0) > ($1.createdDate ?? .distantPast, $1.number ?? 0) }
            .prefix(buildCount)
        guard !latest.isEmpty else { return [] }

        let running = snapshot.runs.filter { BuildStatus(run: $0) == .running }.count
        var items: [NSMenuItem] = [.sectionHeader(title: headerTitle(running: running))]
        for run in latest {
            items.append(buildItem(run, product: products[run.productID], now: now, open: open))
        }
        return items
    }

    static func headerTitle(running: Int) -> String {
        running > 0 ? String(localized: "Latest builds · \(running) running") : String(localized: "Latest builds")
    }

    static func buildItem(_ run: CIBuildRun, product: CIProduct?, now: Date, open: @escaping (URL) -> Void) -> NSMenuItem {
        let url = AppStoreConnectLinks.build(appID: product?.appID, buildRunID: run.id)
        let status = BuildStatus(run: run)
        let item = NSMenuItem.action(plainTitle(run, product: product)) { open(url) }
        item.attributedTitle = attributedTitle(run, product: product, status: status)
        item.badge = NSMenuItemBadge(string: age(of: run, status: status, now: now))
        item.toolTip = [status.label, url.absoluteString].joined(separator: "\n")
        item.setAccessibilityLabel(accessibilityLabel(run, product: product, status: status, age: age(of: run, status: status, now: now)))
        return item
    }

    /// A running build shows how long it has been going; a finished one how long ago it was created.
    static func age(of run: CIBuildRun, status: BuildStatus, now: Date) -> String {
        let reference = status == .running ? (run.startedDate ?? run.createdDate) : run.createdDate
        guard let reference else { return "" }
        return UsageFormat.age(since: reference, now: now)
    }

    /// What VoiceOver reads: the app, the build and its state in words, not the dot.
    static func accessibilityLabel(_ run: CIBuildRun, product: CIProduct?, status: BuildStatus, age: String) -> String {
        [plainTitle(run, product: product), status.label, age].filter { !$0.isEmpty }.formatted(.list(type: .and, width: .narrow))
    }

    static func plainTitle(_ run: CIBuildRun, product: CIProduct?) -> String {
        let number = run.number.map { "#\($0)" } ?? "#?"
        return [appName(product), UsageFormat.dotted([number, run.workflowName].compactMap(\.self))].joined(separator: " ")
    }

    static func attributedTitle(_ run: CIBuildRun, product: CIProduct?, status: BuildStatus) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: appColumnWidth)]
        style.lineBreakMode = .byTruncatingTail

        let font = NSFont.menuFont(ofSize: 0)
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let title = NSMutableAttributedString(attributedString: BuildStatusDot.marker(for: status, font: font))
        title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))
        title.append(NSAttributedString(
            string: appName(product) + "\t",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        ))
        title.append(NSAttributedString(
            string: run.number.map { "#\($0)" } ?? "#?",
            attributes: [.font: bold, .paragraphStyle: style]
        ))
        if let workflow = run.workflowName {
            title.append(NSAttributedString(string: " · \(workflow)", attributes: [.font: font, .paragraphStyle: style]))
        }
        return title
    }

    private static func appName(_ product: CIProduct?) -> String {
        let name = product?.name ?? "?"
        return name.count > maximumAppNameLength ? name.prefix(maximumAppNameLength - 1) + "…" : name
    }
}
