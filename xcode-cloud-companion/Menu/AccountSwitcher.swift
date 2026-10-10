import AppKit
import SwiftUI

/// One account of the switcher at the top of the menu.
struct AccountChoice: Identifiable, Equatable {
    var id: String
    var name: String
    /// What the account's builds are doing, so a failure in the account that is not shown is still seen.
    var badge: MenuBarBadge?
}

/// Where each account sits in the row: the drawing and the clicks read the same figures.
nonisolated enum AccountSwitcherLayout {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 4
    static let height: CGFloat = 26
    static let verticalPadding: CGFloat = 6

    /// The account under a click at `x` in a row `width` wide; nil in the margins and between two accounts.
    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let cell = (width - 2 * inset - CGFloat(count - 1) * spacing) / CGFloat(count)
        guard cell > 0, x >= inset else { return nil }
        let step = cell + spacing
        let index = Int((x - inset) / step)
        guard index < count, x - inset - CGFloat(index) * step <= cell else { return nil }
        return index
    }
}

/// The accounts side by side, the one on screen filled with the accent colour. Drawn only: the clicks are taken by `AccountSwitcherControl`.
struct AccountSwitcherView: View {
    let accounts: [AccountChoice]
    let selectedID: String?
    var select: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: AccountSwitcherLayout.spacing) {
            ForEach(accounts) { account in
                let isSelected = account.id == selectedID
                HStack(spacing: 5) {
                    // The menu under the row already says how the selected account's builds go.
                    if let badge = account.badge, !isSelected {
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
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(account.name))
                .accessibilityValue(Text(account.badge?.status.label ?? ""))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { select(account.id) }
            }
        }
        .padding(.horizontal, AccountSwitcherLayout.inset)
        .padding(.vertical, AccountSwitcherLayout.verticalPadding)
        .frame(minWidth: usageMenuContentWidth)
    }
}

/// The switcher as a menu item's view. A click changes the account and leaves the menu open, so the row takes its
/// clicks in AppKit: a view in a menu gets `mouseUp` for sure, a SwiftUI button there does not always.
final class AccountSwitcherControl: NSView {
    private let hosting: NSHostingView<AccountSwitcherView>
    private var accounts: [AccountChoice]
    private let select: (String) -> Void

    init(accounts: [AccountChoice], selectedID: String?, select: @escaping (String) -> Void) {
        self.accounts = accounts
        self.select = select
        hosting = NSHostingView(rootView: AccountSwitcherView(accounts: accounts, selectedID: selectedID, select: select))
        super.init(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        // The menu widens its items to its widest row: the row follows.
        autoresizingMask = [.width]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AccountSwitcherControl is never decoded")
    }

    /// The account on screen changed while the menu is open: the same row shows it, so the click that did it is not lost.
    func update(accounts: [AccountChoice], selectedID: String?) {
        self.accounts = accounts
        hosting.rootView = AccountSwitcherView(accounts: accounts, selectedID: selectedID, select: select)
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
