import SwiftUI

/// How a state of a TestFlight build is drawn: a shape and a colour beside its word, never the colour alone.
extension TestFlightStatus {
    var systemImage: String {
        switch self {
        case .available: "checkmark"
        case .processing, .waitingForReview, .inReview: "clock"
        case .ready: "circle.dotted"
        case .rejected, .processingFailed: "xmark"
        case .expired: "minus"
        case .unknown: "questionmark"
        }
    }

    var tint: Color? {
        switch self {
        case .available: BuildStatus.succeeded.tint
        case .rejected, .processingFailed: BuildStatus.failed.tint
        case .processing, .waitingForReview, .inReview, .ready, .expired, .unknown: nil
        }
    }
}

/// An app's latest TestFlight builds: their version, their testers, where they stand, and how long they have left.
struct TestFlightCard: View {
    enum Content: Equatable {
        case rows(TestFlightCardModel)
        /// The first read is under way.
        case loading
        /// Apple answered 403: the key cannot read TestFlight.
        case forbidden
    }

    let content: Content
    let appName: String
    let swatch: AppSwatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            switch content {
            case .rows(let model):
                rows(model)
            case .loading:
                rows(.placeholder)
                    .skeleton(true, label: "Reading TestFlight…")
            case .forbidden:
                forbidden
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("TestFlight")
                .fontWeight(.semibold)
                .unredacted()
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                SwatchSquare(color: swatch.color)
                Text(appName).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .unredacted()
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ model: TestFlightCardModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                Divider()
                TestFlightRow(row: row)
            }
        }
    }

    private var forbidden: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This key cannot read TestFlight.").fontWeight(.semibold)
                    Text("Cumulus will not ask again until it restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 9)
            .padding(.bottom, 3)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TestFlightRow: View {
    let row: TestFlightCardModel.Row

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label
                testers
                Spacer(minLength: 8)
                chips
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    label
                    testers
                }
                chips
            }
        }
        .padding(.vertical, 9)
        .foregroundStyle(row.isExpired ? .secondary : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.spoken))
    }

    private var label: some View {
        Text(row.label)
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 74, alignment: .leading)
    }

    @ViewBuilder
    private var testers: some View {
        if let testers = row.testers {
            Text(testers)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            CapsuleTag(text: row.statusText, systemImage: row.status.systemImage, tint: row.status.tint)
            if let expiry = row.expiry {
                CapsuleTag(text: expiry, systemImage: "clock", tint: BuildStatus.errored.tint)
            }
        }
    }
}
