import SwiftUI

/// The content of one row of the native build list: the build's ring, with the app's icon at its centre where apps mix, what was built, then its number, workflow and
/// branch, and on the right how long it took and how long ago.
///
/// The ring says how the build went; the second line names the state in words only when it is not a success. The row draws
/// no background: the list draws the selection, and the colours follow `backgroundProminence` when the row is the chosen one.
struct BuildRow: View {
    let appName: String
    let swatch: AppSwatch
    let ring: BuildRing
    /// A commit's message, a branch's name: what the row is about.
    let title: String
    /// A symbol before the title, for a row that is not a build: the kind of reference.
    var titleSymbol: String?
    /// What stands first on the second line: the build's number.
    var prefix: String?
    /// The state in words, in its colour; nil when the ring and the title say it already.
    var statusText: String?
    var statusTint: Color = .secondary
    /// What follows: the workflow, the branch.
    var facts = ""
    var duration: String?
    var age: String?
    /// Names the app at the ring's centre: only in lists where several apps meet. An app's own list leaves the centre empty.
    var showsApp = false
    var artwork: AppArtwork?
    /// A running build's start: its duration is redrawn every second, the rest of the row is not.
    var runningSince: Date?
    var spokenLabel = ""
    var spokenValue = ""
    static let ringSize: CGFloat = 40
    static let height: CGFloat = 52
    /// Where the text starts, so that the separators line up with it.
    nonisolated static let textInset: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            BuildRingView(
                ring: ring, size: Self.ringSize,
                center: showsApp ? .app(swatch, initial: String(appName.prefix(1)).uppercased(), artwork: artwork) : .none
            )
            .help(showsApp ? appName : "")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let titleSymbol {
                        Image(systemName: titleSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                BuildRowLine(prefix: prefix, statusText: statusText, statusTint: statusTint, facts: facts)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let runningSince {
                    TickingView(interval: 1) { now in
                        Text(BuildRowData.clock(max(0, now.timeIntervalSince(runningSince)))).modifier(DurationStyle())
                    }
                } else if let duration {
                    Text(duration).modifier(DurationStyle())
                }
                if let age {
                    Text(age).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: Self.height)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.textInset }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityValue(Text(UsageFormat.dotted([spokenValue, ring.spokenDescription].filter { !$0.isEmpty })))
    }

    /// “#394 · 3 tests · Release · main”, the state alone in its colour.
    static func line(prefix: String?, statusText: String?, facts: String, tint: Color?) -> AttributedString {
        var line = AttributedString()
        func append(_ part: AttributedString) {
            if !line.characters.isEmpty {
                line += AttributedString(UsageFormat.dotted(["", ""]))
            }
            line += part
        }
        if let prefix, !prefix.isEmpty {
            var part = AttributedString(prefix)
            part.swiftUI.font = .system(.caption, design: .monospaced)
            append(part)
        }
        if let statusText, !statusText.isEmpty {
            var part = AttributedString(statusText)
            part.swiftUI.font = .caption.weight(.semibold)
            if let tint { part.swiftUI.foregroundColor = tint }
            append(part)
        }
        if !facts.isEmpty {
            append(AttributedString(facts))
        }
        return line
    }
}

/// The second line of a row. Read from a view of its own: on the accent of a chosen row the state's colour would drown, so it
/// is left to the list's own text colours there.
private struct BuildRowLine: View {
    let prefix: String?
    let statusText: String?
    let statusTint: Color
    let facts: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(BuildRow.line(prefix: prefix, statusText: statusText, facts: facts, tint: prominence == .increased ? nil : statusTint))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct DurationStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 12, weight: .medium, design: .monospaced))
    }
}

/// The ring of a build for the present moment: worked out once for a finished build, followed by the clock for one that runs
/// or waits, so that only its own row is drawn again.
struct BuildRowRing<Content: View>: View {
    let run: CIBuildRun
    let snapshot: BuildSnapshot
    let now: Date
    @ViewBuilder let content: (BuildRing) -> Content

    var body: some View {
        if run.executionProgress == .complete {
            content(BuildRing(run: run, in: snapshot, now: now))
        } else {
            BuildRingsClock(runs: [run], snapshot: snapshot) { rings in
                content(rings[0])
            }
        }
    }
}

extension BuildRow {
    /// A build of the list: its commit's message for a title, or how it went when Apple gave no message.
    init(row: BuildRowData, ring: BuildRing, now: Date, swatch: AppSwatch, showsApp: Bool = false, artwork: AppArtwork? = nil) {
        let summary = row.summary(now: now)
        self.init(
            appName: row.productName, swatch: swatch, ring: ring,
            title: row.commitTitle ?? summary, prefix: row.numberText,
            statusText: row.rowStatusWord, statusTint: row.status.textTint, facts: row.facts,
            duration: row.duration(now: now), age: row.age(now: now), showsApp: showsApp, artwork: artwork,
            runningSince: row.runningSince,
            spokenLabel: [row.commitTitle, row.numberText, summary].compactMap(\.self).joined(separator: ", "),
            spokenValue: row.spokenDetail
        )
    }
}

#Preview("Rows") {
    let now = Date()
    let started = now.addingTimeInterval(-400)
    let run = CIBuildRun(
        id: "r", productID: "p", number: 7, createdDate: started, startedDate: started, finishedDate: now, executionProgress: .complete,
        completionStatus: .failed, startReason: nil, workflowID: "wf", workflowName: "Release", sourceBranchOrTag: "main"
    )
    let actions = [
        CIBuildAction(
            id: "a", buildRunID: "r", name: "Build", actionType: .build, startedDate: started, finishedDate: started.addingTimeInterval(120),
            executionProgress: .complete, completionStatus: .succeeded, isRequiredToPass: nil
        ),
        CIBuildAction(
            id: "b", buildRunID: "r", name: "Test", actionType: .test, startedDate: started.addingTimeInterval(120),
            finishedDate: started.addingTimeInterval(340), executionProgress: .complete, completionStatus: .failed, isRequiredToPass: nil
        ),
    ]
    let ring = BuildRing(run: run, in: BuildSnapshot(runs: [run], actionsByRunID: ["r": actions]), now: now)
    return List {
        Section {
            BuildRow(
                appName: "Cumulus", swatch: .blue, ring: ring, title: "Fix the CSV import", prefix: "#7", statusText: "3 tests",
                statusTint: BuildStatus.failed.textTint, facts: "Release · main", duration: "6:12", age: "19m"
            )
            BuildRow(
                appName: "Cumulus", swatch: .blue, ring: ring, title: "main", titleSymbol: "arrow.triangle.branch", prefix: nil,
                facts: "Release · #7", age: "1h"
            )
        } header: {
            DayHeader(title: "Today")
        }
    }
    .listStyle(.inset)
    .frame(width: 372, height: 200)
}
