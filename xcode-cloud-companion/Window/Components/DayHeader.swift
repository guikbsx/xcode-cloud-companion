import SwiftUI

/// A day heading of the build list ("Aujourd'hui", "Hier", "Cette semaine"…): the header of a section of the native list, which
/// the list keeps at the top while its rows scroll.
struct DayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
