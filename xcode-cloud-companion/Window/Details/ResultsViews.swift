import AppKit
import SwiftUI

/// Copies a message or a path, and opens a file in Xcode only when it exists on this Mac.
enum SourceActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func existsLocally(_ path: String?) -> Bool {
        path.map { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) } ?? false
    }

    static func openInXcode(_ path: String) {
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Progress, or the reason a load stopped, above the results of a tab.
struct LoadStatusView: View {
    let state: ExtrasLoadState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading(let done, let total):
            HStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 220)
                Text("Loading \(done) of \(total)").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message, _, _):
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(BuildStatus.errored.tint).font(.callout)
                Button("Try Again", action: retry)
            }
        case .idle, .loaded:
            EmptyView()
        }
    }
}

private struct SourceLine: View {
    let location: String?
    let path: String?
    let message: String?

    var body: some View {
        HStack(spacing: 10) {
            if let location {
                Text(location).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let path {
                Button("Copy Path") { SourceActions.copy(path) }.buttonStyle(.borderless)
                if SourceActions.existsLocally(path) {
                    Button("Open in Xcode") { SourceActions.openInXcode(path) }.buttonStyle(.borderless)
                }
            }
            if let message {
                Button("Copy Message") { SourceActions.copy(message) }.buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }
}

struct TestsTabView: View {
    let results: [String: [CITestResult]]
    let actions: [CIBuildAction]
    let state: ExtrasLoadState
    let retry: () -> Void

    @State private var actionID: String?
    @State private var status = TestStatusFilter.all
    @State private var destination: String?
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []

    var body: some View {
        let model = TestsTabModel(results: results, actions: actions, actionID: actionID, status: status, destination: destination)
        VStack(alignment: .leading, spacing: 12) {
            LoadStatusView(state: state, retry: retry)
            if !results.isEmpty || state == .loaded {
                filters(model)
                if model.groups.isEmpty {
                    Text(state == .loaded && results.values.allSatisfy(\.isEmpty) ? "This build has no test results." : "No test matches these filters.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { group in
                            groupView(group)
                            Divider()
                        }
                    }
                    .cumulusGroup()
                }
            }
        }
    }

    private func filters(_ model: TestsTabModel) -> some View {
        HStack {
            if model.actionChoices.count > 1 {
                Picker("Action", selection: $actionID) {
                    Text("All actions").tag(String?.none)
                    ForEach(model.actionChoices) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Picker("Status", selection: $status) {
                Text("All").tag(TestStatusFilter.all)
                Text("Failed").tag(TestStatusFilter.failed)
                Text("Passed").tag(TestStatusFilter.passed)
                Text("Skipped").tag(TestStatusFilter.skipped)
                Text("Expected failure").tag(TestStatusFilter.expectedFailure)
            }
            if model.destinations.count > 1 {
                Picker("Destination", selection: $destination) {
                    Text("All destinations").tag(String?.none)
                    ForEach(model.destinations, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Spacer()
            Text("\(model.total) tests · \(model.failed) failed").font(.caption).foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A class with failures opens by itself; the others stay closed until asked.
    private func isOpen(_ group: TestGroup) -> Binding<Bool> {
        Binding(
            get: { group.failedCount > 0 ? !collapsed.contains(group.id) : expanded.contains(group.id) },
            set: { open in
                if group.failedCount > 0 {
                    if open { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } else {
                    if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
                }
            }
        )
    }

    private func groupView(_ group: TestGroup) -> some View {
        DisclosureGroup(isExpanded: isOpen(group)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.rows) { row in
                    rowView(row)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(group.className).fontWeight(.semibold)
                Spacer()
                Text("\(group.passedCount) passed (\(UsageFormat.percent(group.passedFraction)))")
                    .font(.caption)
                    .foregroundStyle(group.failedCount > 0 ? BuildStatus.failed.tint : .secondary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowView(_ row: TestRow) -> some View {
        let hasDetail = row.message != nil || row.location != nil || !row.devices.isEmpty
        if hasDetail {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = row.message {
                        Text(message).font(.callout).textSelection(.enabled)
                    }
                    SourceLine(location: row.location, path: row.path, message: row.message)
                    ForEach(Array(row.devices.enumerated()), id: \.offset) { _, device in
                        HStack(spacing: 8) {
                            StatusBadge(status: device.status.buildStatus, size: 14)
                            Text("\(device.deviceName) · \(device.osVersion)").font(.caption)
                            Spacer()
                            if let duration = device.duration {
                                Text(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                rowLabel(row)
            }
        } else {
            rowLabel(row).padding(.leading, 20)
        }
    }

    private func rowLabel(_ row: TestRow) -> some View {
        HStack(spacing: 8) {
            StatusBadge(status: row.status.buildStatus, size: 18)
            Text(row.name).font(.callout).lineLimit(1)
            Spacer()
            if let duration = row.duration {
                Text(duration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct IssuesTabView: View {
    let issues: [String: [CIIssue]]
    let actions: [CIBuildAction]
    let state: ExtrasLoadState
    let retry: () -> Void

    var body: some View {
        let model = IssuesTabModel(issues: issues, actions: actions)
        VStack(alignment: .leading, spacing: 12) {
            LoadStatusView(state: state, retry: retry)
            if model.groups.isEmpty {
                if state == .loaded {
                    Text("No issue recorded for this build.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.actionName)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        ForEach(group.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: row.type.systemImage)
                                        .foregroundStyle(row.type.severity <= 1 ? BuildStatus.failed.tint : BuildStatus.errored.tint)
                                        .accessibilityLabel(row.type.label)
                                    Text(row.message).textSelection(.enabled)
                                }
                                HStack(spacing: 10) {
                                    if let category = row.category {
                                        Text(category).font(.caption).foregroundStyle(.secondary)
                                    }
                                    SourceLine(location: row.location, path: row.path, message: row.message)
                                }
                                .padding(.leading, 24)
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cumulusGroup()
                }
            }
        }
    }
}

struct ArtifactsTabView: View {
    let artifacts: [String: [CIArtifact]]
    let actions: [CIBuildAction]
    let state: ExtrasLoadState
    let saver: ArtifactSaver
    let retry: () -> Void

    var body: some View {
        let groups = actions.compactMap { action in artifacts[action.id].flatMap { $0.isEmpty ? nil : (action, $0) } }
        VStack(alignment: .leading, spacing: 12) {
            LoadStatusView(state: state, retry: retry)
            if groups.isEmpty {
                if state == .loaded {
                    Text("This build produced no downloadable file.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups, id: \.0.id) { action, files in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(action.name ?? "?")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        ForEach(files) { file in
                            row(file)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cumulusGroup()
                }
            }
        }
    }

    private func row(_ file: CIArtifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.fileName ?? file.kindLabel).textSelection(.enabled)
                    Text(UsageFormat.dotted([file.kindLabel, file.fileSize.map { $0.formatted(.byteCount(style: .file)) }].compactMap(\.self)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch saver.state(of: file.id) {
                case .preparing:
                    ProgressView().controlSize(.small)
                case .downloading(let fraction):
                    HStack(spacing: 8) {
                        if let fraction {
                            ProgressView(value: fraction).frame(width: 90)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { saver.cancel(file.id) }
                    }
                case .saved(let url):
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                case .idle, .failed:
                    Button("Save…") { saver.start(file) }
                }
            }
            if case .failed(let message) = saver.state(of: file.id) {
                Text(message).font(.caption).foregroundStyle(BuildStatus.errored.tint)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
