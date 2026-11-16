import SwiftUI

/// What stands where the “In Brief” card would be, whatever the state of the feature: the card when it is open, and nothing
/// at all when Apple Intelligence or the setting says no.
struct FailureInsightSection: View {
    let run: CIBuildRun
    let store: FailureInsightStore
    @AppStorage(FailureInsightFeature.settingKey) private var isSettingOn = true

    var body: some View {
        switch FailureInsightFeature.mode(model: .current, settingOn: isSettingOn) {
        case .hidden: EmptyView()
        case .open: FailureInsightCard(run: run, store: store)
        }
    }
}

/// The “In Brief” card of a failed build: its category, decided by rules, and a sentence the model wrote on this Mac.
/// Until the load ends, it stands as a skeleton of itself; a load that ends without a record takes the card away.
struct FailureInsightCard: View {
    let run: CIBuildRun
    let store: FailureInsightStore
    @State private var hasAttempted = false

    var body: some View {
        let record = store.insight(for: run.id)
        let isSkeleton = SkeletonRules.failureInsight(hasRecord: record != nil, isLoading: store.isLoading(run.id), hasAttempted: hasAttempted)
        Group {
            if let shown = record ?? (isSkeleton ? .placeholder : nil) {
                card(shown)
                    .skeleton(isSkeleton, label: "In Brief, loading")
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .task(id: run.id) {
            await store.load(run)
            hasAttempted = true
        }
    }

    private var heading: some View {
        Text("In Brief", comment: "Heading of the card that sums up a failed build in one sentence")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .unredacted()
    }

    private func card(_ record: FailureInsightRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                heading
                Spacer(minLength: 8)
                CapsuleTag(text: record.category.displayName)
            }
            if let headline = record.headline {
                Text(verbatim: headline)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    InsightSparkle()
                    Text("Generated on this Mac by Apple Intelligence · may be wrong", comment: "Under the one-sentence summary of a failed build")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
        .accessibilityElement(children: .contain)
    }
}

/// The mark of what the model wrote; grey in a skeleton, which has not been written yet.
private struct InsightSparkle: View {
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        Image(systemName: "sparkles")
            .foregroundStyle(redaction.isSkeleton ? Color.skeleton : CumulusStyle.accent)
            .accessibilityHidden(true)
    }
}
