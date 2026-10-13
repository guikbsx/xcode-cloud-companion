import AppKit
import SwiftUI

/// One account of the switcher at the top of the menu.
struct AccountChoice: Identifiable, Equatable {
    var id: String
    var name: String
    /// What the account's builds are doing, so a failure in the account that is not shown is still seen.
    var badge: MenuBarBadge?
    /// Not followed for want of Cumulus Pro: picking it leads to the purchase sheet.
    var isPaused = false
}

extension AccountChoice {
    /// The accounts of the switcher; none while there is one account only. A paused account says nothing of its
    /// builds: they are not followed.
    static func all(of accounts: AccountsModel) -> [AccountChoice] {
        guard accounts.hasSeveral else { return [] }
        return accounts.sessions.map { session in
            let isPaused = accounts.isPaused(session)
            return AccountChoice(
                id: session.id, name: session.name, badge: isPaused ? nil : MenuBarBadge.status(for: session.buildStore.snapshot), isPaused: isPaused
            )
        }
    }
}

/// Where each account sits in the row: the drawing and the clicks read the same figures.
nonisolated enum AccountSwitcherLayout {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 4
    static let height: CGFloat = 26
    static let verticalPadding: CGFloat = 6

    /// ⌘1 to ⌘9 reach the first nine accounts: a view in a menu gets no key, so hidden items carry them.
    static let shortcutCount = 9

    /// Where each account is drawn in a row `width` wide, from left to right.
    static func frames(width: CGFloat, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let cell = (width - 2 * inset - CGFloat(count - 1) * spacing) / CGFloat(count)
        guard cell > 0 else { return [] }
        return (0..<count).map { CGRect(x: inset + CGFloat($0) * (cell + spacing), y: verticalPadding, width: cell, height: height) }
    }

    /// The account under a click at `x` in a row `width` wide; nil in the margins and between two accounts.
    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
        frames(width: width, count: count).firstIndex { x >= $0.minX && x <= $0.maxX }
    }
}

/// The accounts side by side, the one on screen filled with the accent colour. Drawn only: the clicks, and what
/// VoiceOver reads, are `AccountSwitcherControl`'s.
struct AccountSwitcherView: View {
    let accounts: [AccountChoice]
    let selectedID: String?

    var body: some View {
        HStack(spacing: AccountSwitcherLayout.spacing) {
            ForEach(accounts) { account in
                let isSelected = account.id == selectedID
                HStack(spacing: 5) {
                    // The menu under the row already says how the selected account's builds go.
                    if account.isPaused {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                    } else if let badge = account.badge, !isSelected {
                        Circle()
                            .fill(Color(nsColor: badge.color))
                            .frame(width: 6, height: 6)
                    }
                    Text(account.name)
                        .font(.system(size: NSFont.systemFontSize, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: AccountSwitcherLayout.height)
                .foregroundStyle(isSelected ? Color.white : account.isPaused ? Color.secondary : Color.primary)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, AccountSwitcherLayout.inset)
        .padding(.vertical, AccountSwitcherLayout.verticalPadding)
        .frame(minWidth: usageMenuContentWidth)
        .accessibilityHidden(true)
    }
}

/// One account as VoiceOver meets it: a radio button of the row, selected when its account is on screen. Everything it
/// says is worked out by the row; pressing it hands the account back to the main actor.
nonisolated final class AccountSwitcherElement: NSAccessibilityElement {
    private let press: @MainActor @Sendable () -> Void

    init(label: String, isSelected: Bool, help: String?, frame: CGRect, parent: NSView, press: @escaping @MainActor @Sendable () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
        setAccessibilityValue(NSNumber(value: isSelected))
        setAccessibilityHelp(help)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        Task { @MainActor in press() }
        return true
    }
}

/// The switcher as a menu item's view. A click changes the account and leaves the menu open, so the row takes its
/// clicks in AppKit: a view in a menu gets `mouseUp` for sure, a SwiftUI button there does not always.
final class AccountSwitcherControl: NSView {
    private let hosting: NSHostingView<AccountSwitcherView>
    private var accounts: [AccountChoice]
    private var selectedID: String?
    private let select: (String) -> Void

    init(accounts: [AccountChoice], selectedID: String?, select: @escaping (String) -> Void) {
        self.accounts = accounts
        self.select = select
        self.selectedID = selectedID
        hosting = NSHostingView(rootView: AccountSwitcherView(accounts: accounts, selectedID: selectedID))
        super.init(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        // The menu widens its items to its widest row: the row follows.
        autoresizingMask = [.width]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "Account"))
        refreshToolTip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AccountSwitcherControl is never decoded")
    }

    /// The account on screen changed while the menu is open: the same row shows it, so the click that did it is not lost.
    func update(accounts: [AccountChoice], selectedID: String?) {
        self.accounts = accounts
        self.selectedID = selectedID
        hosting.rootView = AccountSwitcherView(accounts: accounts, selectedID: selectedID)
        refreshToolTip()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The row is a drawing, not controls: VoiceOver is given one radio button per account, where each is drawn.
    override func accessibilityChildren() -> [Any]? {
        let frames = AccountSwitcherLayout.frames(width: bounds.width, count: accounts.count)
        return zip(accounts, frames).enumerated().map { index, pair in
            let (account, frame) = pair
            let isSelected = account.id == selectedID
            // The menu under the row already says how the selected account's builds go.
            let status = account.isPaused
                ? String(localized: "paused, needs Cumulus Pro", comment: "VoiceOver, after the name of an account that is not followed without Cumulus Pro.")
                : isSelected ? nil : account.badge?.status.label
            let select = select
            return AccountSwitcherElement(
                label: status.map { "\(account.name), \($0)" } ?? account.name,
                isSelected: isSelected,
                help: index < AccountSwitcherLayout.shortcutCount
                    ? String(localized: "Shortcut: ⌘\(index + 1)", comment: "VoiceOver help of an account in the menu's switcher; the digit selects that account.")
                    : nil,
                frame: frame, parent: self, press: { select(account.id) }
            )
        }
    }

    /// The shortcuts are carried by hidden items: this is where they can be learnt.
    private func refreshToolTip() {
        let last = min(accounts.count, AccountSwitcherLayout.shortcutCount)
        toolTip = last > 1 ? String(localized: "Switch accounts with ⌘1 to ⌘\(last)", comment: "Tooltip of the account switcher in the menu; the digit is the number of accounts, 9 at most.") : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let index = AccountSwitcherLayout.index(at: point.x, width: bounds.width, count: accounts.count) else { return }
        select(accounts[index].id)
    }
}
