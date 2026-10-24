import SwiftUI

extension View {
    /// A light system fill behind a row of a native list while the pointer is on it, as in the Finder's list or Mail. The
    /// chosen row keeps the list's own selection and takes nothing more; nothing moves.
    func listRowHover(isSelected: Bool) -> some View {
        modifier(ListRowHover(isSelected: isSelected))
    }
}

private struct ListRowHover: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .listRowBackground(
                isHovering && !isSelected
                    ? RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)).padding(.horizontal, 10) : nil
            )
    }
}
