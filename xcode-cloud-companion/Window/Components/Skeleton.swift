import SwiftUI

/// The grey of a shape drawn in a skeleton: tinted capsules, rings and bars read the redaction and take this instead of their colour.
extension Color {
    static let skeleton = Color.primary.opacity(0.14)
}

extension RedactionReasons {
    var isSkeleton: Bool { contains(.placeholder) }
}

/// Redacts a view into grey shapes that breathe, for a section whose data has not arrived. The view stays the same
/// view whether it loads or not, so its state and its tasks go through the arrival of the data untouched.
private struct SkeletonModifier: ViewModifier {
    let isLoading: Bool
    let label: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .redacted(reason: isLoading ? .placeholder : [])
            .opacity(isDimmed ? 0.4 : 1)
            .allowsHitTesting(!isLoading)
            .accessibilityHidden(isLoading)
            .overlay {
                if isLoading {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(Text(label))
                }
            }
            .onChange(of: isLoading, initial: true) { _, loading in breathe(loading) }
            .onChange(of: reduceMotion) { breathe(isLoading) }
    }

    private func breathe(_ loading: Bool) {
        if loading, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isDimmed = true }
        } else {
            withTransaction(Transaction(animation: nil)) { isDimmed = false }
        }
    }
}

extension View {
    /// Shows this view as a loading skeleton while `isLoading`: grey shapes in place of its text, slowly dimming and
    /// brightening, out of reach of clicks, and one “Loading” element for VoiceOver. Known text stays readable with `unredacted()`.
    func skeleton(_ isLoading: Bool, label: LocalizedStringKey = "Loading") -> some View {
        modifier(SkeletonModifier(isLoading: isLoading, label: label))
    }
}

/// The small coloured square before an app's or a workflow's name: grey in a skeleton, which has no colour to give.
struct SwatchSquare: View {
    let fill: AnyShapeStyle
    var side: CGFloat = 9
    @Environment(\.redactionReasons) private var redaction

    init(color: Color, side: CGFloat = 9) {
        self.init(fill: AnyShapeStyle(color), side: side)
    }

    init(fill: AnyShapeStyle, side: CGFloat = 9) {
        self.fill = fill
        self.side = side
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(redaction.isSkeleton ? AnyShapeStyle(Color.skeleton) : fill)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}
