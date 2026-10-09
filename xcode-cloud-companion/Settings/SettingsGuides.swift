import SwiftUI

/// One numbered step of a guide, with an optional block (button, diagram) under its text.
struct GuideStep<Content: View>: View {
    let number: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A schematic of an App Store Connect page: the values to copy are highlighted.
private struct SchemaFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func highlighted() -> some View {
        padding(.horizontal, 5)
            .background(Color.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Where the Issuer ID and the key ID sit on App Store Connect's Integrations page.
struct APIKeySchema: View {
    var body: some View {
        SchemaFrame {
            Text("Issuer ID", comment: "Label in the diagram of App Store Connect's Integrations page").foregroundStyle(.secondary)
            Text(verbatim: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx").font(.caption.monospaced()).highlighted()
            Divider().padding(.vertical, 2)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Name", comment: "Column of the key table in App Store Connect")
                    Text("Key ID", comment: "Column of the key table in App Store Connect")
                    Text("Access", comment: "Column of the key table in App Store Connect")
                }
                .foregroundStyle(.secondary)
                GridRow {
                    Text(verbatim: "Cumulus")
                    Text(verbatim: "ABCDE12345").font(.caption.monospaced()).highlighted()
                    Text("Developer", comment: "Access level of an API key, as App Store Connect names it in its own language")
                }
            }
        }
    }
}

/// Where the plan's hours and the reset date sit on App Store Connect's Xcode Cloud usage page.
struct UsageSchema: View {
    var body: some View {
        SchemaFrame {
            Text("Compute hours", comment: "Label in the diagram of App Store Connect's Xcode Cloud usage page").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(verbatim: "[H] h").font(.callout.weight(.semibold))
                Text("used of", comment: "Between the hours used and the plan's hours in the diagram")
                Text(verbatim: "[25] h").fontWeight(.semibold).highlighted()
            }
            Capsule().fill(.quaternary).frame(height: 5)
            HStack(spacing: 4) {
                Text("Resets on", comment: "Before the reset date in the diagram")
                Text("[DD Month YYYY]", comment: "Placeholder of a date in the diagram of App Store Connect's usage page").fontWeight(.semibold).highlighted()
            }
        }
    }
}
