import SwiftUI

/// A pane of Settings: its sections in one grouped form, or shared between two forms side by side once the pane is
/// wide enough for both. The same rule as the sheets of the main window, on equal halves: these are forms alike.
///
/// A section never spans both columns: a grouped form caps its own width (about 700 points), so one above two halves
/// would sit narrower than them, centred. What opens a pane heads its first column; only a `header`, drawn here and
/// not by a form, goes across the pane.
struct SettingsColumns<Header: View, Single: View, Leading: View, Trailing: View>: View {
    private let header: Header?
    private let single: Single?
    private let leading: Leading
    private let trailing: Trailing
    @State private var columns = DetailColumns.one

    private init(header: Header?, single: Single?, leading: Leading, trailing: Trailing) {
        self.header = header
        self.single = single
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        Group {
            if columns == .two {
                // One scroll for both: two forms that scrolled on their own would drift apart.
                ScrollView {
                    VStack(spacing: 0) {
                        if let header {
                            header
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, SettingsCard.inset)
                                .padding(.vertical, 10)
                                .background(SettingsCard.fill, in: .rect(cornerRadius: SettingsCard.radius))
                                .padding([.horizontal, .top], SettingsCard.margin)
                        }
                        HStack(alignment: .top, spacing: 0) {
                            half { leading }
                            half { trailing }
                        }
                    }
                }
            } else {
                Form {
                    if let header {
                        Section {
                            header
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        }
                    }
                    if let single {
                        single
                    } else {
                        leading
                        trailing
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onGeometryChange(for: DetailColumns.self) { DetailColumns(width: $0.size.width) } action: { columns = $0 }
    }

    private func half(@ViewBuilder _ sections: () -> some View) -> some View {
        Form(content: sections)
            .formStyle(.grouped)
            .scrollDisabled(true)
            // As tall as its sections: the scroll around both halves does the scrolling.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a grouped form draws around a section, measured on the system's own (12/10/2026): the header that spans the
/// pane is drawn to match.
private enum SettingsCard {
    static let margin: CGFloat = 20
    static let inset: CGFloat = 10
    static let radius: CGFloat = 10
    static let fill = Color.primary.opacity(0.03)
}

extension SettingsColumns where Header == EmptyView, Single == EmptyView {
    /// A pane whose sections read the same on one column: the first column's, then the second's.
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(header: nil, single: nil, leading: leading(), trailing: trailing())
    }
}

extension SettingsColumns where Single == EmptyView {
    /// A pane with a header across it, whatever the number of columns under it.
    init(@ViewBuilder header: () -> Header, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(header: header(), single: nil, leading: leading(), trailing: trailing())
    }
}

extension SettingsColumns where Header == EmptyView {
    /// `single` is the pane on one column, when its sections do not simply follow each other, first column then second.
    init(@ViewBuilder single: () -> Single, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(header: nil, single: single(), leading: leading(), trailing: trailing())
    }
}
