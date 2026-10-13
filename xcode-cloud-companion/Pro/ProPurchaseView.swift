import AppKit
import SwiftUI

/// The sheet where Cumulus Pro is bought: what it brings, the two products at the App Store's prices, and the way back.
struct ProPurchaseView: View {
    @Bindable var model: ProPurchaseModel

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.store.isPro {
                owned
            } else {
                benefits
                offer
            }
            Divider()
            footer
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
        .frame(width: Self.width)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cumulus Pro")
                    .font(.title2.bold())
                Text("The alerts, the diagnostics, the agents, several teams.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var owned: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(ProEntitlementText.title(model.store.entitlement), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(ProEntitlementText.detail(model.store.entitlement))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.benefits, id: \.self) { benefit in
                Label {
                    Text(benefit.title)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var offer: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the App Store for the prices…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
        case .unavailable:
            VStack(spacing: 8) {
                Text("The App Store did not give the prices. Check the connection, then try again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    Task { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76)
        case .ready, .purchasing, .pending, .failed:
            products
        }
    }

    private var products: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(model.offers) { offer in
                    ProOfferCard(offer: offer, isSelected: model.selectedOffer?.product == offer.product) {
                        model.selection = offer.product
                    }
                }
            }
            .disabled(model.isBusy)

            if let offer = model.selectedOffer {
                Button {
                    Task { await model.buy() }
                } label: {
                    Text(ProPurchaseText.buttonTitle(for: offer))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)

                Text(ProPurchaseText.finePrint(for: offer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            switch model.phase {
            case .pending:
                Label("Waiting for approval. Cumulus Pro opens as soon as the purchase is approved.", systemImage: "hourglass")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = model.restoreNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                if !model.store.isPro {
                    Button("Restore Purchases") {
                        Task { await model.restore() }
                    }
                    .disabled(model.isBusy)
                }
                Link("Terms of Use", destination: ProLinks.termsOfUse)
                Link("Privacy", destination: ProLinks.privacyPolicy)
                Spacer(minLength: 8)
                Button(model.store.isPro ? "Done" : "Not Now") {
                    model.dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.link)
            .font(.footnote)
        }
    }
}

/// One product: its name, the App Store's price, and what sets it apart. Selecting it does not buy it.
private struct ProOfferCard: View {
    let offer: ProOffer
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ProPurchaseText.name(of: offer.product))
                    .fontWeight(.semibold)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(offer.displayPrice)
                        .font(.title3.bold())
                    if offer.product == .yearly {
                        Text("per year")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(ProPurchaseText.tagline(for: offer))
                    .font(.footnote)
                    .foregroundStyle(offer.trialDays != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(ProPurchaseText.name(of: offer.product)), \(offer.displayPrice), \(ProPurchaseText.tagline(for: offer))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
