import SwiftUI

/// The sidebar's refresh: a button while nothing is asked of Apple; while something is, its symbol turns and it takes no click.
///
/// The symbol is the one of a running action in the frieze. It stays in place from one state to the other, so the toolbar
/// does not move.
struct RefreshButton: View {
    let control: RefreshControl
    let refresh: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            // A button that only stopped taking clicks can still be reached from the keyboard.
            guard control.allowsRefresh else { return }
            refresh()
        } label: {
            Label(title, systemImage: BuildStatus.running.systemImage)
                .symbolEffect(.rotate, options: .repeat(.periodic(delay: 0)), isActive: isBusy && !reduceMotion)
                // Without motion nothing would tell the two states apart: the system's spinner takes over.
                .opacity(isBusy && reduceMotion ? 0 : 1)
                .overlay {
                    if isBusy, reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
        // Disabled, the symbol would fade while it turns: while busy, the button only stops listening.
        .allowsHitTesting(!isBusy)
        .disabled(control.isHeld)
        .help(help)
    }

    private var isBusy: Bool {
        control == .busy
    }

    private var title: String {
        isBusy ? String(localized: "Updating…") : String(localized: "Refresh")
    }

    private var help: String {
        switch control {
        case .ready:
            String(localized: "Refresh this account’s builds", comment: "Tooltip of the toolbar's refresh button.")
        case .busy:
            String(localized: "Updating…")
        case .held(.rateLimited):
            String(localized: "Apple is limiting this key’s requests. Cumulus tries again on its own.", comment: "Tooltip of the refresh button, disabled after a 429.")
        case .held(.lowBudget):
            String(localized: "This key has few requests left this hour. Cumulus keeps refreshing on its own, more slowly.", comment: "Tooltip of the refresh button, disabled while the hourly budget is nearly spent.")
        }
    }
}

#Preview("Actualiser") {
    HStack(spacing: 16) {
        RefreshButton(control: .ready, refresh: {})
        RefreshButton(control: .busy, refresh: {})
        RefreshButton(control: .held(.rateLimited), refresh: {})
    }
    .padding(20)
}
