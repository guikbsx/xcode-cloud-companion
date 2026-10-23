import SwiftUI

/// What the card needs from the account to give a build to groups.
struct TestFlightDistributionAccess {
    let groups: TestFlightGroupsStore
    let distributor: TestFlightDistributor
    /// The builds Cumulus has read: where the previous build to expire is looked for.
    let testFlight: TestFlightStore
    /// The account's “Key access” is “Read + Build”.
    let canWrite: Bool
    let openSettings: () -> Void
    /// Apple said 403: the key goes read only.
    let notAllowed: () -> Void
}

/// The TestFlight card of a build that reached TestFlight: its groups, checked where the build is, and the foot that says
/// what would change. Checking a box sends nothing; “Give Access” opens a confirmation, and only its button sends.
struct TestFlightDistributionCard: View {
    let build: TestFlightBuild
    let appID: String
    /// The app's name, for the confirmation of an expiration.
    let appName: String?
    let access: TestFlightDistributionAccess
    let teamID: String?
    let now: Date

    enum Phase: Equatable {
        case idle
        case sending(Set<String>)
        /// A write did not go through: Apple's words, whether nothing at all changed, and whether App Store Connect can help.
        case failed(message: String, nothingChanged: Bool, pointsToAppStoreConnect: Bool)
        /// 403: the key may not distribute.
        case forbidden(String)
        /// Apple accepted, and the build could not be read back yet.
        case unconfirmed
        /// Apple is expiring the build.
        case expiring
        /// The groups were given, and the previous build could not be expired: its name and the reason.
        case expirationFailed(label: String, message: String)
    }

    /// The boxes as the user left them; nil until one is touched, so they follow what Apple says.
    @State private var selection: Set<String>?
    @State private var isConfirming = false
    @State private var isAskingToExpire = false
    @State private var phase: Phase

    /// `selection` and `phase` start the card somewhere other than at rest: a render of one of its states, a preview.
    init(
        build: TestFlightBuild, appID: String, appName: String? = nil, access: TestFlightDistributionAccess, teamID: String?, now: Date,
        selection: Set<String>? = nil, phase: Phase = .idle
    ) {
        self.build = build
        self.appID = appID
        self.appName = appName
        self.access = access
        self.teamID = teamID
        self.now = now
        _selection = State(initialValue: selection)
        _phase = State(initialValue: phase)
    }

    private var groups: [BetaGroup]? {
        access.groups.groups(for: appID)
    }

    private var isSkeleton: Bool {
        SkeletonRules.testFlightGroups(hasGroups: !(groups ?? []).isEmpty, hasAttempted: access.groups.hasAttempted(appID))
    }

    private var model: TestFlightDistributionCardModel {
        guard let groups, !groups.isEmpty else { return .placeholder }
        return .make(
            build: build, groups: groups, canWrite: access.canWrite, now: now,
            expiredSeenAt: access.testFlight.lookup(buildID: build.id)?.observation?.expiredSeenAt
        )
    }

    private var previousBuild: PreviousBuild? {
        PreviousBuild.find(before: build, among: access.testFlight.builds(forAppID: appID), groups: groups ?? [], now: now)
    }

    private var members: Set<String> {
        TestFlightDistributionPlan.members(of: build, in: groups ?? [])
    }

    private var plan: TestFlightDistributionPlan {
        TestFlightDistributionPlan.make(groups: groups ?? [], members: members, selected: selection ?? members)
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("TestFlight")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .unredacted()
            header(model)
            if case .forbidden(let message) = phase {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                content(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cumulusGroup()
        .skeleton(isSkeleton)
        .task(id: appID) {
            await access.groups.load(appID: appID)
        }
        .onChange(of: build) {
            selection = nil
            if phase == .unconfirmed { phase = .idle }
        }
        .sheet(isPresented: $isConfirming) {
            TestFlightDistributionSheet(build: build, plan: plan, previous: previousBuild, distributor: access.distributor) { notes, notify, expiring in
                isConfirming = false
                Task { await send(notes: notes, notify: notify, expiring: expiring) }
            }
        }
    }

    private func header(_ model: TestFlightDistributionCardModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane").foregroundStyle(.tint).accessibilityHidden(true)
            Text("Build \(model.label)").fontWeight(.semibold)
            Spacer(minLength: 8)
            CapsuleTag(text: phaseStatusText ?? model.statusText)
            actionsMenu(model)
        }
    }

    private func actionsMenu(_ model: TestFlightDistributionCardModel) -> some View {
        Menu {
            Button(TestFlightExpiration.copyBuildNumber) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(build.buildNumber ?? build.label, forType: .string)
            }
            Button(TestFlightExpiration.openInAppStoreConnect) {
                NSWorkspace.shared.open(AppStoreConnectLinks.testFlight(appID: appID, teamID: teamID))
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(TestFlightExpiration.moreActions)
        .help(TestFlightExpiration.moreActions)
    }

    private var phaseStatusText: String? {
        if phase == .expiring { return TestFlightExpiration.expiring }
        if case .failed(_, true, _) = phase { return String(localized: "Not sent", comment: "State of a TestFlight build whose distribution Apple refused") }
        return nil
    }

    @ViewBuilder
    private func content(_ model: TestFlightDistributionCardModel) -> some View {
        if let message = model.message {
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if model.showsGroups {
            groupsList(model)
        }
        switch model.mode {
        case .readOnlyKey:
            Button("Open Settings…", action: access.openSettings)
        case .missingCompliance:
            appStoreConnectButton
        case .open:
            if case .failed(let message, let nothingChanged, let pointsToAppStoreConnect) = phase {
                failure(message, nothingChanged: nothingChanged, pointsToAppStoreConnect: pointsToAppStoreConnect)
            } else if case .expirationFailed(let label, let message) = phase {
                expirationFailure(label: label, message: message)
            } else if phase == .unconfirmed {
                Text("Apple accepted the change. The card shows it as soon as it can read the build.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            foot(model)
        case .processing, .processingFailed, .expired:
            EmptyView()
        }
    }

    private func groupsList(_ model: TestFlightDistributionCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Groups").fontWeight(.semibold).unredacted()
            block(String(localized: "Internal", comment: "Heading of the internal TestFlight groups"), model.internalRows, model: model)
            block(String(localized: "External", comment: "Heading of the external TestFlight groups"), model.externalRows, model: model)
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ rows: [TestFlightDistributionCardModel.Row], model: TestFlightDistributionCardModel) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary).unredacted()
                ForEach(rows) { row in
                    groupRow(row, isEditable: model.isEditable && !isSending, isDimmed: model.mode == .expired)
                }
            }
        }
    }

    private var isSending: Bool {
        if case .sending = phase { return true }
        return phase == .expiring
    }

    private func groupRow(_ row: TestFlightDistributionCardModel.Row, isEditable: Bool, isDimmed: Bool) -> some View {
        let isChecked = row.receivesEveryBuild || (selection ?? members).contains(row.id)
        return Toggle(isOn: Binding(
            get: { isChecked },
            set: { checked in
                var next = selection ?? members
                if checked { next.insert(row.id) } else { next.remove(row.id) }
                selection = next
                if case .failed = phase { phase = .idle }
            }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name).foregroundStyle(row.receivesEveryBuild || isDimmed ? .secondary : .primary)
                        if row.receivesEveryBuild {
                            Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    if let note = row.note {
                        Text(note).font(.caption).foregroundStyle(row.isInternal ? Color.secondary : Color.orange.mix(with: .primary, by: 0.35))
                    }
                }
                Spacer(minLength: 8)
                trailing(row)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!isEditable || row.receivesEveryBuild)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ row: TestFlightDistributionCardModel.Row) -> some View {
        if case .sending(let ids) = phase, ids.contains(row.id) {
            ProgressView().controlSize(.small)
        } else if let badge = row.badge {
            CapsuleTag(text: badge.text, tint: Self.tint(of: badge.tone))
        } else if let testers = row.testers {
            Text(testers).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    private static func tint(of tone: TestFlightDistributionCardModel.Badge.Tone) -> Color {
        switch tone {
        case .available: BuildStatus.succeeded.tint
        case .awaitingReview, .inReview: .orange
        case .rejected: BuildStatus.failed.tint
        }
    }

    private func foot(_ model: TestFlightDistributionCardModel) -> some View {
        let plan = plan
        let words = isSending ? String(localized: "Sending…") : TestFlightDistributionText.summary(plan)
        let summary = Text(words ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
        let button = Button(isSending ? String(localized: "Sending…") : String(localized: "Give Access", comment: "Button that gives a TestFlight build to groups")) { isConfirming = true }
            .buttonStyle(.borderedProminent)
            .disabled(plan.isEmpty || isSending || phase == .unconfirmed)
        let expire = Button(TestFlightExpiration.expireItem, role: .destructive) { askToExpire() }
            .buttonStyle(.bordered)
            .disabled(isSending || phase == .expiring)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if model.canExpire { expire }
                Spacer(minLength: 8)
                if words != nil { summary.lineLimit(1) }
                button
            }
            VStack(alignment: .leading, spacing: 8) {
                if words != nil { summary }
                HStack(spacing: 8) {
                    if model.canExpire { expire }
                    Spacer(minLength: 8)
                    button
                }
            }
        }
    }

    private func failure(_ message: String, nothingChanged: Bool, pointsToAppStoreConnect: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(BuildStatus.errored.tint)
                .fixedSize(horizontal: false, vertical: true)
            if nothingChanged {
                Text("Nothing was changed.").font(.callout).foregroundStyle(.secondary)
            }
            if pointsToAppStoreConnect { appStoreConnectButton }
        }
    }

    private func expirationFailure(label: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label {
                Text(verbatim: "\(TestFlightExpiration.previousFailed(label: label)) \(message)")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(BuildStatus.errored.tint)
            .fixedSize(horizontal: false, vertical: true)
            Text(TestFlightExpiration.groupsUpdated).font(.callout).foregroundStyle(.secondary)
            appStoreConnectButton
        }
    }

    private var appStoreConnectButton: some View {
        Button {
            NSWorkspace.shared.open(AppStoreConnectLinks.testFlight(appID: appID, teamID: teamID))
        } label: {
            Label("Open in App Store Connect", systemImage: "arrow.up.forward.app")
        }
    }

    private func askToExpire() {
        let title = TestFlightExpiration.alertTitle(appName: appName, label: build.label)
        let message = TestFlightExpiration.alertMessage(for: build, groups: groups ?? [])
        Task {
            guard await ExpirationAlert.confirm(title: title, message: message) else { return }
            await expire()
        }
    }

    private func expire() async {
        phase = .expiring
        let outcome = await access.distributor.expire(buildID: build.id)
        switch outcome {
        case .expired(let read):
            selection = nil
            phase = read == nil ? .unconfirmed : .idle
        case .notAllowed(let message):
            access.notAllowed()
            phase = .forbidden(message)
        case .refused(let message):
            phase = .failed(message: message, nothingChanged: true, pointsToAppStoreConnect: true)
        case .rateLimited, .failed:
            phase = .failed(message: outcome.message ?? "", nothingChanged: true, pointsToAppStoreConnect: false)
        case .uncertain:
            selection = nil
            phase = .failed(message: outcome.message ?? "", nothingChanged: false, pointsToAppStoreConnect: false)
        }
    }

    private func send(notes: DistributionNotes?, notify: Bool?, expiring previousID: String?) async {
        let plan = plan
        guard !plan.isEmpty else { return }
        phase = .sending(Set(plan.toAdd.map(\.id) + plan.toRemove.map(\.id)))
        let previousLabel = previousBuild.flatMap { $0.build.id == previousID ? $0.build.label : nil }
        let result = await access.distributor.distribute(
            DistributionRequest(build: build, add: plan.toAdd, remove: plan.toRemove, notes: notes, notify: notify), thenExpiring: previousID
        )
        let outcome = result.distribution
        // The boxes follow what Apple says as soon as something was accepted or may have been; after a refusal that changed nothing they stay, for another try.
        if !outcome.completed.isEmpty || outcome.isAccepted { selection = nil }
        switch outcome {
        case .accepted(_, let read):
            phase = read == nil ? .unconfirmed : .idle
        case .notAllowed(let message, _):
            access.notAllowed()
            phase = .forbidden(message)
        case .refused(let message, _, let completed):
            phase = .failed(message: outcome.message ?? message, nothingChanged: completed.isEmpty, pointsToAppStoreConnect: true)
        case .uncertain:
            selection = nil
            phase = .failed(message: outcome.message ?? "", nothingChanged: false, pointsToAppStoreConnect: false)
        case .rateLimited, .failed:
            phase = .failed(message: outcome.message ?? "", nothingChanged: outcome.completed.isEmpty, pointsToAppStoreConnect: false)
        }
        if let expiration = result.expiration, !expiration.isExpired {
            if case .notAllowed = expiration { access.notAllowed() }
            phase = .expirationFailed(label: previousLabel ?? "", message: expiration.message ?? "")
        }
    }
}

/// The last question before a build is expired: Cancel is the default button, so a stray Return keeps the build.
@MainActor
enum ExpirationAlert {
    static func confirm(title: String, message: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: TestFlightExpiration.alertCancel)
        alert.addButton(withTitle: TestFlightExpiration.alertConfirm).hasDestructiveAction = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }
}

/// The confirmation before a build is given to groups or taken from them: it names the build and the groups, takes the test
/// notes and whether the testers are told, and sends nothing itself.
struct TestFlightDistributionSheet: View {
    let build: TestFlightBuild
    let plan: TestFlightDistributionPlan
    /// The older build that could be expired with this one; nil when there is none.
    var previous: PreviousBuild?
    let distributor: TestFlightDistributor
    let confirm: (DistributionNotes?, Bool?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Apple's notes for the build, read when the sheet opens; nil while unread or when they could not be.
    @State private var existing: [BetaBuildNote]?
    @State private var notesEnded = false
    @State private var locale = ""
    @State private var text = ""
    @State private var notify = true
    @State private var expiresPrevious = false

    private var model: TestFlightDistributionSheetModel {
        .make(label: build.label, plan: plan)
    }

    private var addsGroups: Bool { !plan.toAdd.isEmpty }

    private var choices: [String] {
        TestFlightNoteLocales.choices(existing: existing ?? [])
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 16) {
            Text(model.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(model.lines) { line in
                    Divider()
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.title).fontWeight(.semibold)
                            Text(line.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        CapsuleTag(text: line.chip.text, tint: Self.tint(of: line.chip))
                    }
                    .padding(.vertical, 7)
                }
            }
            if addsGroups {
                notesEditor
                Toggle("Notify testers", isOn: $notify)
                    .toggleStyle(.switch)
                if let previous {
                    previousToggle(previous)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.confirmButton) { confirm(notes, addsGroups ? notify : nil, addsGroups && expiresPrevious ? previous?.build.id : nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { notify = build.autoNotifyEnabled ?? true }
        .task {
            guard addsGroups else { return }
            existing = await distributor.notes(for: build.id)
            notesEnded = true
            guard let initial = TestFlightNoteLocales.initial(choices: choices) else { return }
            locale = initial
            text = existing?.first { $0.locale == initial }?.text ?? ""
        }
    }

    private func previousToggle(_ previous: PreviousBuild) -> some View {
        Toggle(isOn: $expiresPrevious) {
            VStack(alignment: .leading, spacing: 1) {
                Text(TestFlightExpiration.previousToggle(label: previous.build.label))
                Text(TestFlightExpiration.previousDetail(groupCount: previous.groupCount)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// The notes sent with the groups: nil when Apple's could not be read, so nothing is written over them blind.
    private var notes: DistributionNotes? {
        guard addsGroups, let existing else { return nil }
        return DistributionNotes(locale: locale, text: text, existing: existing.first { $0.locale == locale })
    }

    @ViewBuilder
    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Test notes").font(.callout.weight(.semibold))
                Spacer()
                if existing != nil, choices.count > 1 {
                    Picker("Language", selection: $locale) {
                        ForEach(choices, id: \.self) { Text(TestFlightNoteLocales.name($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: locale) { _, new in
                        text = existing?.first { $0.locale == new }?.text ?? ""
                    }
                } else if let only = choices.first, existing != nil {
                    Text(TestFlightNoteLocales.name(only)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if existing != nil {
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: .rect(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                    .accessibilityLabel(Text("Test notes"))
            } else if notesEnded {
                Text("The test notes couldn’t be read, so they are left as they are.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private static func tint(of chip: TestFlightDistributionSheetModel.Line.Chip) -> Color {
        switch chip {
        case .rightAway: BuildStatus.succeeded.tint
        case .betaReview: .orange
        case .removed: .secondary
        }
    }
}
