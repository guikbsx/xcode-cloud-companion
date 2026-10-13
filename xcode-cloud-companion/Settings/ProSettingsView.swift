import AppKit
import StoreKit
import SwiftUI

/// What the Cumulus Pro pane offers to do in each state of Pro.
nonisolated enum ProSettingsAction: Hashable, Sendable {
    /// Opens the purchase sheet, to buy or to buy again.
    case purchase
    /// The App Store's own page, where a subscription is changed or stopped.
    case manageSubscription
    case restore
    /// The App Store's own sheet for an offer code.
    case redeemCode

    static func actions(for entitlement: ProEntitlement) -> [ProSettingsAction] {
        switch entitlement {
        case .free, .expired: [.purchase, .restore, .redeemCode]
        case .trial, .subscribed: [.manageSubscription]
        case .lifetime: []
        }
    }

    /// Where macOS lets a subscriber manage what they pay for.
    static let subscriptionsPage = URL(string: "https://apps.apple.com/account/subscriptions")!
}

/// Settings › Cumulus Pro: where Pro stands, what it adds, and the way to the purchase sheet. The sheet does the
/// selling; this pane never shows a price.
struct ProSettingsView: View {
    let store: ProStore
    let openPurchase: () -> Void
    @State private var isRestoring = false
    @State private var restoreNote: String?
    @State private var isRedeeming = false

    private var actions: [ProSettingsAction] { ProSettingsAction.actions(for: store.entitlement) }

    var body: some View {
        SettingsColumns {
            Section {
                state
                if actions.contains(.restore) {
                    restore
                }
                if actions.contains(.redeemCode) {
                    LabeledContent("Have an offer code?") {
                        Button("Redeem a Code…") { isRedeeming = true }
                    }
                }
            }
        } trailing: {
            Section {
                ForEach(ProBenefit.allCases, id: \.self) { benefit in
                    Label {
                        Text(benefit.title)
                    } icon: {
                        Image(systemName: store.isPro ? "checkmark" : "lock")
                            .foregroundStyle(store.isPro ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
            } header: {
                Text(benefitsTitle)
            } footer: {
                HStack(spacing: 14) {
                    Link("Terms of Use", destination: ProLinks.termsOfUse)
                    Link("Privacy", destination: ProLinks.privacyPolicy)
                }
                .font(.footnote)
            }
        }
        // On the pane, not in a section: the two forms change identity when the pane gets its second column.
        .offerCodeRedemption(isPresented: $isRedeeming) { _ in
            Task { await store.refresh() }
        }
    }

    private var benefitsTitle: LocalizedStringKey {
        if store.isPro { return "What Pro Adds" }
        if case .expired = store.entitlement { return "Paused Until Pro Resumes" }
        return "What Pro Adds"
    }

    private var state: some View {
        LabeledContent {
            if actions.contains(.purchase) {
                Button(purchaseTitle, action: openPurchase)
                    .buttonStyle(.borderedProminent)
            } else if actions.contains(.manageSubscription) {
                Button("Manage Subscription…") {
                    NSWorkspace.shared.open(ProSettingsAction.subscriptionsPage)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(ProEntitlementText.title(store.entitlement))
                } icon: {
                    if store.isPro {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                .labelStyle(.titleAndIcon)
                Text(ProEntitlementText.detail(store.entitlement))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var purchaseTitle: LocalizedStringKey {
        if case .expired = store.entitlement { return "Resume Cumulus Pro…" }
        return "Discover Cumulus Pro…"
    }

    private var restore: some View {
        LabeledContent {
            Button("Restore Purchases") {
                Task {
                    isRestoring = true
                    let answered = await store.restore()
                    isRestoring = false
                    restoreNote = store.isPro ? nil : (answered
                        ? String(localized: "No Cumulus Pro purchase was found for this Apple Account.")
                        : String(localized: "The App Store could not be reached. Try again in a moment."))
                }
            }
            .disabled(isRestoring)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Already bought Cumulus Pro?")
                if let restoreNote {
                    Text(restoreNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
