import Foundation
import Observation

/// What Cumulus Pro brings, in the app's own words. Each line stands for the functions it opens.
nonisolated enum ProBenefit: CaseIterable, Sendable {
    case alerts, diagnostics, workflows, agents, accounts

    var features: [ProFeature] {
        switch self {
        case .alerts: [.earlyUsageAlerts, .stuckBuildAlert, .slowdownAlert, .testFlightTracking, .webhookAlerts]
        case .diagnostics: [.regressions, .failureInsight, .logExcerpt, .testHealth, .workflowTrends, .workflowCostBreakdown, .upcomingBuilds, .appOverview, .olderBuilds, .openInXcode]
        case .workflows: [.pauseWorkflow, .editWorkflow]
        case .agents: [.commandLine, .mcpServer]
        case .accounts: [.multipleAccounts]
        }
    }

    var title: String {
        switch self {
        case .alerts: String(localized: "Warned at 75 % of the plan, on the pace, when a build is stuck, when a workflow slows down or when a TestFlight build reaches testers or expires, and in Slack or a webhook")
        case .diagnostics: String(localized: "What broke, flaky tests, trends and what a workflow costs")
        case .workflows: String(localized: "Pause a workflow, change its Xcode version")
        case .agents: String(localized: "The cumulus command and the MCP server for your agents")
        case .accounts: String(localized: "Several App Store Connect accounts")
        }
    }

    /// The benefit one came for is read first.
    static func ordered(for origin: ProFeature?) -> [ProBenefit] {
        guard let origin, let first = allCases.first(where: { $0.features.contains(origin) }) else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }
}

nonisolated enum ProLinks {
    /// Apple's standard licence agreement, which Cumulus sells under.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://cumulus.guik.io/privacy/")!
}

/// The words of the purchase sheet that depend on the offer. A price is always the App Store's.
nonisolated enum ProPurchaseText {
    static func trialLength(days: Int, locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        let components = days % 30 == 0 ? DateComponents(month: days / 30) : DateComponents(day: days)
        return formatter.string(from: components) ?? "\(days)"
    }

    static func buttonTitle(for offer: ProOffer, locale: Locale = .autoupdatingCurrent) -> String {
        switch offer.product {
        case .yearly:
            if let days = offer.trialDays {
                return String(localized: "Try Free for \(trialLength(days: days, locale: locale))", comment: "Purchase button. The placeholder is a length such as “1 month”.")
            }
            return String(localized: "Subscribe for \(offer.displayPrice) per Year")
        case .lifetime:
            return String(localized: "Buy for \(offer.displayPrice)")
        }
    }

    /// What Apple asks an offer to say: its length, its price, that it renews, and how to stop it.
    static func finePrint(for offer: ProOffer) -> String {
        switch offer.product {
        case .yearly:
            offer.trialDays != nil
                ? String(localized: "Then \(offer.displayPrice) per year, renewed automatically. Cancel at any time in your App Store account.")
                : String(localized: "\(offer.displayPrice) per year, renewed automatically. Cancel at any time in your App Store account.")
        case .lifetime:
            String(localized: "One payment. No subscription.")
        }
    }

    static func name(of product: ProProduct) -> String {
        switch product {
        case .yearly: String(localized: "Yearly")
        case .lifetime: String(localized: "Lifetime")
        }
    }

    static func tagline(for offer: ProOffer, locale: Locale = .autoupdatingCurrent) -> String {
        switch offer.product {
        case .yearly:
            offer.trialDays.map { String(localized: "\(trialLength(days: $0, locale: locale)) free trial", comment: "Under the yearly price. The placeholder is a length such as “1 month”.") }
                ?? String(localized: "Renewed every year")
        case .lifetime:
            String(localized: "One payment")
        }
    }
}

/// The purchase sheet: which product is chosen, what the App Store answered, and when to close.
@Observable
final class ProPurchaseModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// The App Store gave no product: nothing to buy is shown, only a way to ask again.
        case unavailable
        case purchasing
        case pending
        case failed(String)
    }

    let store: ProStore
    /// The locked function the sheet was opened from, if any.
    let origin: ProFeature?
    var selection: ProProduct = .yearly
    private(set) var phase: Phase = .loading
    private(set) var isRestoring = false
    /// What a restore found, when it did not open Pro.
    private(set) var restoreNote: String?
    private let close: () -> Void

    init(store: ProStore, origin: ProFeature? = nil, close: @escaping () -> Void) {
        self.store = store
        self.origin = origin
        self.close = close
    }

    var offers: [ProOffer] { store.offers }
    var selectedOffer: ProOffer? { offers.first { $0.product == selection } ?? offers.first }
    var benefits: [ProBenefit] { ProBenefit.ordered(for: origin) }
    var isBusy: Bool { phase == .purchasing || isRestoring }

    func load() async {
        guard !store.isPro else {
            phase = .ready
            return
        }
        phase = .loading
        await store.loadOffers()
        if !offers.contains(where: { $0.product == selection }), let first = offers.first {
            selection = first.product
        }
        phase = offers.isEmpty ? .unavailable : .ready
    }

    func buy() async {
        guard let offer = selectedOffer, !isBusy else { return }
        phase = .purchasing
        restoreNote = nil
        switch await store.purchase(offer.product) {
        case .purchased:
            phase = .ready
            close()
        case .cancelled:
            phase = .ready
        case .pending:
            phase = .pending
        case .unavailable:
            phase = .unavailable
        case .failed(let message):
            phase = .failed(message)
        }
    }

    func restore() async {
        guard !isBusy else { return }
        isRestoring = true
        restoreNote = nil
        let answered = await store.restore()
        isRestoring = false
        if store.isPro {
            close()
        } else {
            restoreNote = answered
                ? String(localized: "No Cumulus Pro purchase was found for this Apple Account.")
                : String(localized: "The App Store could not be reached. Try again in a moment.")
        }
    }

    func dismiss() {
        close()
    }
}
