import SwiftUI
import WidgetKit

extension WidgetSnapshot.Tint {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}

extension WidgetSnapshot.BuildState {
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

    var color: Color {
        switch self {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .errored: .orange
        case .canceled, .skipped, .finished: .gray
        }
    }

    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .errored: "exclamationmark.circle.fill"
        case .canceled, .skipped: "minus.circle.fill"
        case .finished: "circle.fill"
        }
    }
}

extension WidgetSnapshot.Build {
    /// “#394 · Release”, and what failed when tests did.
    var facts: String {
        var parts = [number.map { "#\($0)" }, workflow].compactMap(\.self)
        if let failedTests {
            parts.append(String(localized: "\(failedTests) tests", comment: "Widget: how many tests failed in the build"))
        }
        return UsageFormat.dotted(parts)
    }

    /// “Failed · CI”: the state in words, then the workflow.
    var stateLine: String {
        UsageFormat.dotted([state.label, workflow].compactMap(\.self))
    }
}

extension WidgetSnapshot.Cycle {
    /// “~13 hr, 37 min of 25 hr”: the tilde says the figure is Cumulus's estimate, not Apple's billing.
    var usedLine: String {
        let used = (isEstimate ? "~" : "") + UsageFormat.minutes(usedMinutes)
        return String(localized: "\(used) of \(UsageFormat.minutes(quotaMinutes))", comment: "Widget: the compute time used, then the plan")
    }

    var percentText: String {
        UsageFormat.compactPercent(Double(percentUsed) / 100)
    }

    var resetLine: String {
        String(localized: "Resets \(UsageFormat.day(resetDate))", comment: "Widget: the day the cycle starts again")
    }
}

/// Something to say in place of the figures: no account yet, no plan, builds still measured.
struct WidgetMessage: View {
    let title: Text
    var detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "cloud")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            title.font(.headline)
            if let detail {
                detail.font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    static let noAccount = WidgetMessage(title: Text("Open Cumulus"), detail: Text("Add your App Store Connect key to see your builds here."))
    static let noBuild = WidgetMessage(title: Text("No build yet"))
    static let noPlan = WidgetMessage(title: Text("No plan set"), detail: Text("Set the reset date in Cumulus to follow the cycle."))
    static let measuring = WidgetMessage(title: Text("Measuring usage…"), detail: Text("The figure shows once every build of the cycle is measured."))
}

/// The app's coloured square with its initial: the extension has the colour, not the icon.
struct AppBadge: View {
    let name: String
    let tint: WidgetSnapshot.Tint
    var size: CGFloat = 20

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.color, in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// The age of a build, counted by the system so that it stays right between two reloads.
struct BuildAge: View {
    let date: Date?

    var body: some View {
        if let date {
            // One unit only: “5 min”, “1 hr”, “2 days”.
            Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Latest build, small

struct LatestBuildView: View {
    let face: WidgetSnapshot.BuildFace

    var body: some View {
        Group {
            switch face {
            case .noAccount: WidgetMessage.noAccount
            case .noBuild: WidgetMessage.noBuild
            case .build(let build): content(build).widgetURL(build.url)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func content(_ build: WidgetSnapshot.Build) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                AppBadge(name: build.app, tint: build.tint)
                Text(build.app).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Image(systemName: build.state.symbol)
                    .font(.title2)
                    .foregroundStyle(build.state.color)
                    .accessibilityHidden(true)
                Text(build.state.label).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(build.facts).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
            Spacer(minLength: 4)
            HStack {
                if let seconds = build.durationSeconds {
                    Text(UsageFormat.minutes(Double(seconds) / 60))
                }
                Spacer(minLength: 4)
                BuildAge(date: build.date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - The cycle

/// A ring cut by app over the plan; what is not used stays as the track.
struct CycleRing: View {
    let cycle: WidgetSnapshot.Cycle
    var lineWidth: CGFloat = 10
    var caption: Text?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            ForEach(Array(cycle.arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.tint.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(cycle.percentText).font(.system(.title3, design: .rounded).weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
                if let caption {
                    caption.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(lineWidth + 4)
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(cycle.percentText) of the plan used", comment: "Widget, VoiceOver: the share of the plan used this cycle"))
    }
}

struct CycleBar: View {
    let cycle: WidgetSnapshot.Cycle

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                HStack(spacing: 0) {
                    ForEach(Array(cycle.arcs.enumerated()), id: \.offset) { _, arc in
                        Rectangle().fill(arc.tint.color).frame(width: proxy.size.width * (arc.end - arc.start))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A build on one line: its state as a dot, its name, its age.
struct BuildRow: View {
    let build: WidgetSnapshot.Build
    /// Off in the small widget, where the name needs the whole line: no state line under it, no age beside it.
    var showsState = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(build.state == .running ? Color.clear : build.state.color)
                    .overlay { if build.state == .running { Circle().strokeBorder(build.state.color, lineWidth: 2) } }
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(build.title).font(.caption.weight(.semibold)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if showsState {
                    BuildAge(date: build.date).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showsState {
                Text(build.stateLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CycleRingSmallView: View {
    let face: WidgetSnapshot.CycleFace
    let latest: WidgetSnapshot.Build?

    var body: some View {
        Group {
            switch face {
            case .noAccount: WidgetMessage.noAccount
            case .noPlan: WidgetMessage.noPlan
            case .measuring: WidgetMessage.measuring
            case .cycle(let cycle):
                VStack(spacing: 4) {
                    CycleRing(cycle: cycle).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let latest {
                        BuildRow(build: latest, showsState: false)
                    }
                    Text(cycle.usedLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .widgetURL(URL(string: "cumulus://overview"))
        .containerBackground(.background, for: .widget)
    }
}

/// The medium widgets: the cycle on the left, as a bar or as a ring, and the latest builds on the right.
struct CycleAndBuildsView: View {
    enum Style {
        case bar, ring
    }

    let style: Style
    let face: WidgetSnapshot.CycleFace
    let builds: [WidgetSnapshot.Build]
    let hasAccount: Bool

    var body: some View {
        Group {
            if hasAccount {
                HStack(alignment: .center, spacing: 14) {
                    cycleSide.frame(width: 124)
                    Divider()
                    buildsSide
                }
            } else {
                WidgetMessage.noAccount
            }
        }
        .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var cycleSide: some View {
        Link(destination: URL(string: "cumulus://overview") ?? URL(filePath: "/")) {
            switch face {
            case .noAccount: WidgetMessage.noAccount
            case .noPlan: WidgetMessage.noPlan
            case .measuring: WidgetMessage.measuring
            case .cycle(let cycle):
                switch style {
                case .bar:
                    VStack(alignment: .leading, spacing: 0) {
                        Text("This cycle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(cycle.percentText)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        CycleBar(cycle: cycle).padding(.top, 4)
                        Spacer(minLength: 4)
                        Text(cycle.usedLine).lineLimit(2).minimumScaleFactor(0.8)
                        Text(cycle.resetLine).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                case .ring:
                    VStack(spacing: 4) {
                        CycleRing(cycle: cycle, lineWidth: 11, caption: Text("of the plan", comment: "Widget: under the percentage at the centre of the ring"))
                        Text(cycle.usedLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var buildsSide: some View {
        if builds.isEmpty {
            WidgetMessage.noBuild
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(builds.enumerated()), id: \.element.id) { index, build in
                    if index > 0 { Spacer(minLength: 2) }
                    Link(destination: build.url ?? URL(filePath: "/")) {
                        BuildRow(build: build)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
