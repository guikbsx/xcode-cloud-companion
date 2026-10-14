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

    /// The shape in the dot of a build row, as the app draws it (`BuildStatus.systemImage`): the state never rests on colour alone.
    var dotGlyph: String? {
        switch self {
        case .running, .finished: nil
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .errored: "exclamationmark"
        case .canceled, .skipped: "minus"
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

    /// What VoiceOver reads for the row, since the dot that shows the state is hidden from it.
    var spokenLine: String {
        let age = date?.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return [title, state.label, workflow, age].compactMap(\.self).joined(separator: ", ")
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
            Self.text(for: date)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
    }

    /// One unit only: “5 min”, “1 hr”, “2 days”.
    static func text(for date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
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

/// A build's state: a disc with its shape in white, a hollow ring while it runs.
struct BuildStateDot: View {
    static let size: CGFloat = 13
    let state: WidgetSnapshot.BuildState

    var body: some View {
        Circle()
            .fill(state == .running ? Color.clear : state.color)
            .overlay {
                if state == .running {
                    Circle().strokeBorder(state.color, lineWidth: 2)
                } else if let glyph = state.dotGlyph {
                    Image(systemName: glyph).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}

/// A build on two lines: its state as a dot and its name on the whole width, then the workflow and the age.
struct BuildRow: View {
    let build: WidgetSnapshot.Build
    /// Off in the small widget, where the name needs the whole line: no line under it.
    var showsDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                BuildStateDot(state: build.state)
                Text(build.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if showsDetails, build.workflow != nil || build.date != nil {
                HStack(spacing: 0) {
                    if let workflow = build.workflow {
                        Text(workflow).lineLimit(1)
                        if build.date != nil { Text(verbatim: " • ").layoutPriority(1) }
                    }
                    if let date = build.date {
                        BuildAge(date: date).layoutPriority(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, BuildStateDot.size + 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(build.spokenLine)
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
                        BuildRow(build: latest, showsDetails: false)
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

// MARK: - Previews

private extension WidgetSnapshot {
    /// Long names, every kind of state and ages in minutes, hours and days: what a narrow row has to hold.
    static var previewLongNames: WidgetSnapshot {
        let now = Date()
        let green = Tint(red: 0.20, green: 0.62, blue: 0.40)
        let blue = Tint(red: 0.29, green: 0.47, blue: 0.90)
        var snapshot = Feed.sample
        snapshot.builds = [
            .init(id: "long-1", appID: "d", app: "Crossfit Hyrox Tracker", number: 12, workflow: "Default", state: .succeeded, date: now.addingTimeInterval(-300), durationSeconds: 540, tint: green),
            .init(id: "long-2", appID: "e", app: "Cumulus", number: 7, workflow: "Release Candidate Archive", state: .failed, failedTests: 2, date: now.addingTimeInterval(-36_000), durationSeconds: 300, tint: blue),
            .init(id: "long-3", appID: "d", app: "Crossfit Hyrox Tracker", number: 11, workflow: "Default", state: .errored, date: now.addingTimeInterval(-2 * 86_400), durationSeconds: 420, tint: green),
        ]
        return snapshot
    }

    static var previewMeasuring: WidgetSnapshot {
        var snapshot = Feed.sample
        snapshot.cycle?.isMeasuring = true
        return snapshot
    }

    static var previewNoPlan: WidgetSnapshot {
        var snapshot = Feed.sample
        snapshot.cycle = nil
        return snapshot
    }
}

#Preview("Latest Build", as: .systemSmall) {
    LatestBuildWidget()
} timeline: {
    FeedEntry(date: .now, snapshot: Feed.sample)
    FeedEntry(date: .now, snapshot: .previewLongNames)
    FeedEntry(date: .now, snapshot: .empty(at: .now))
}

#Preview("Cycle", as: .systemSmall) {
    CycleRingWidget()
} timeline: {
    FeedEntry(date: .now, snapshot: Feed.sample)
    FeedEntry(date: .now, snapshot: .previewMeasuring)
    FeedEntry(date: .now, snapshot: .previewNoPlan)
    FeedEntry(date: .now, snapshot: .empty(at: .now))
}

#Preview("Cycle and Builds", as: .systemMedium) {
    CycleBarWidget()
} timeline: {
    FeedEntry(date: .now, snapshot: Feed.sample)
    FeedEntry(date: .now, snapshot: .previewLongNames)
    FeedEntry(date: .now, snapshot: .previewMeasuring)
    FeedEntry(date: .now, snapshot: .previewNoPlan)
    FeedEntry(date: .now, snapshot: .empty(at: .now))
}

#Preview("Cycle Ring and Builds", as: .systemMedium) {
    CycleRingBuildsWidget()
} timeline: {
    FeedEntry(date: .now, snapshot: Feed.sample)
    FeedEntry(date: .now, snapshot: .previewLongNames)
    FeedEntry(date: .now, snapshot: .previewMeasuring)
    FeedEntry(date: .now, snapshot: .empty(at: .now))
}
