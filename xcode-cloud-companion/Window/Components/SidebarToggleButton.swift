import SwiftUI

/// Shows and hides the sidebar of a split view, from the toolbar.
///
/// A SwiftUI scene gets this button for free; Cumulus hosts its split views in `NSWindow`s, where it does not come.
struct SidebarToggleButton: View {
    @Binding var visibility: NavigationSplitViewVisibility
    /// What the split view shows once its sidebar is gone: its two other columns, or its detail alone.
    let hidden: NavigationSplitViewVisibility

    var body: some View {
        Button {
            withAnimation { visibility = Self.next(after: visibility, hidden: hidden) }
        } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.leading")
        }
        .help("Show or hide the sidebar")
    }

    /// The sidebar goes when every column shows, and comes back from any other state. Both windows start from `.all`:
    /// `.automatic` is not used, because it compares equal to `.doubleColumn` (seen on 12/10/2026) and would read as a
    /// hidden sidebar.
    nonisolated static func next(after visibility: NavigationSplitViewVisibility, hidden: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        visibility == .all ? hidden : .all
    }
}
