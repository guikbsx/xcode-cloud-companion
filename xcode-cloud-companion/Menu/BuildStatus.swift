import AppKit

/// What a build is doing or how it ended, for every dot and label of the menu.
nonisolated enum BuildStatus: Sendable, Equatable {
    case running
    case succeeded
    case failed
    case errored
    case canceled
    case skipped
    case finished

    init(run: CIBuildRun) {
        switch (run.executionProgress, run.completionStatus) {
        case (.pending, _), (.running, _): self = .running
        case (_, .succeeded?): self = .succeeded
        case (_, .failed?): self = .failed
        case (_, .errored?): self = .errored
        case (_, .canceled?): self = .canceled
        case (_, .skipped?): self = .skipped
        default: self = .finished
        }
    }

    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .errored: String(localized: "Error")
        case .canceled: String(localized: "Canceled")
        case .skipped: String(localized: "Skipped")
        case .finished: String(localized: "Finished")
        }
    }

    /// System colours, so the dots follow light, dark and increased contrast.
    var color: NSColor {
        switch self {
        case .running: .systemBlue
        case .succeeded: .systemGreen
        case .failed: .systemRed
        case .errored: .systemOrange
        case .canceled, .skipped, .finished: .systemGray
        }
    }
}

extension AppSwatch {
    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .cyan: .systemCyan
        case .yellow: .systemYellow
        case .purple: .systemPurple
        case .orange: .systemOrange
        case .mint: .systemMint
        case .gray: .systemGray
        }
    }
}

/// The coloured dots of the menu: a tinted character at the head of the title. This menu draws no `NSMenuItem.image`,
/// and a text glyph keeps the system colours in every appearance.
enum BuildStatusDot {
    /// A dot in the status colour; with the system's "Differentiate without color", a shape of its own per state
    /// (the colour stays, it is only no longer the sole carrier). A running build always gets a ringed dot.
    static func glyph(for status: BuildStatus, differentiating: Bool = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor) -> String {
        guard differentiating else { return status == .running ? "\u{25C9}" : "\u{25CF}" }
        switch status {
        case .running: return "\u{25C9}"
        case .succeeded: return "\u{2713}"
        case .failed: return "\u{2715}"
        case .errored: return "!"
        case .canceled: return "\u{2298}"
        case .skipped: return "\u{2212}"
        case .finished: return "\u{25CF}"
        }
    }

    /// The status dot, then, for an app row, a small square in the app's colour; followed by a space.
    static func marker(
        for status: BuildStatus, appSwatch: AppSwatch? = nil, font: NSFont = .menuFont(ofSize: 0),
        differentiating: Bool = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    ) -> NSAttributedString {
        let glyph = glyph(for: status, differentiating: differentiating)
        let isDot = glyph == "\u{25CF}" || glyph == "\u{25C9}"
        let marker = NSMutableAttributedString(
            string: glyph,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize * (isDot ? 0.8 : 1), weight: .bold),
                .foregroundColor: status.color,
                .baselineOffset: isDot ? 0.5 : 0,
            ]
        )
        if let appSwatch {
            marker.append(NSAttributedString(
                string: " \u{25A0}",
                attributes: [.font: NSFont.systemFont(ofSize: font.pointSize * 0.8), .foregroundColor: appSwatch.nsColor]
            ))
        }
        marker.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return marker
    }

    /// `title` behind the marker, in the menu font.
    static func title(_ title: String, status: BuildStatus, appSwatch: AppSwatch? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: marker(for: status, appSwatch: appSwatch))
        result.append(NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return result
    }
}
