import Foundation

/// The readable form of an answer, for a person at a terminal.
nonisolated struct CLIRenderer: Sendable {
    var width: Int
    var now: Date
    var calendar: Calendar

    func text(_ response: CLIResponse) -> String {
        var sections: [String]
        switch response.report {
        case .accounts(let accounts): sections = [self.accounts(accounts)]
        case .status(let status): sections = [self.status(status)]
        case .apps(let apps): sections = [self.apps(apps)]
        case .builds(let builds): sections = [self.builds(builds)]
        case .build(let detail): sections = self.build(detail)
        case .workflows(let workflows): sections = [self.workflows(workflows)]
        case .usage(let usage): sections = self.usage(usage)
        case .refresh(let refresh): sections = self.refresh(refresh)
        case .launch(let launch): sections = self.launch(launch)
        case .testFlight(let testFlight): sections = self.testFlight(testFlight)
        case .testFlightChange(let change): sections = self.testFlightChange(change)
        }
        sections.append(footer(response.meta))
        return sections.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func footer(_ meta: CLIMeta) -> String {
        var lines: [String] = []
        if meta.isEstimate {
            lines.append(CLIText.estimateFootnote)
        }
        if meta.showsAccount, let account = meta.account {
            lines.append("Account: \(account)")
        }
        lines.append(meta.lastSuccessfulSync.map { "Last sync: \(CLIText.date($0, calendar: calendar)) (\(CLIText.age(since: $0, now: now)))" } ?? "Last sync: never")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Status and usage

    private func usageFields(_ usage: UsageOutput) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("Cycle", "\(CLIText.date(usage.cycleStart, calendar: calendar)) to \(CLIText.date(usage.resetDate, calendar: calendar)) (resets in \(CLIText.timeLeft(until: usage.resetDate, now: now)))"),
            ("Used", "\(CLIText.minutes(usage.usedMinutes, estimated: usage.estimatedMinutes > 0)) of \(usage.planHours)h (\(CLIText.percent(CLINumber.wholePercentFraction(usedMinutes: usage.usedMinutes, quotaMinutes: usage.quotaMinutes))))"),
            ("  Billed", CLIText.minutes(usage.billedMinutes) + (usage.lastImport.map { ", export imported \(CLIText.age(since: $0, now: now))" } ?? ", no usage export imported")),
            ("  Estimated", "\(CLIText.minutes(usage.estimatedMinutes, estimated: true)) (\(usage.estimatedBuildCount) builds)"),
            ("Remaining", CLIText.minutes(usage.remainingMinutes, estimated: usage.estimatedMinutes > 0)),
        ]
        if let projected = usage.projectedMinutes {
            fields.append(("Projected", "\(CLIText.minutes(projected, estimated: true)) at reset"))
        }
        if let exhaustion = usage.exhaustionDate {
            fields.append(("Runs out", CLIText.date(exhaustion, calendar: calendar)))
        }
        if let note = usage.note {
            fields.append(("Note", note))
        }
        return fields
    }

    private func status(_ status: StatusOutput) -> String {
        var fields = status.usage.map(usageFields) ?? []
        fields.append(("Running", status.runningBuilds == 1 ? "1 build" : "\(status.runningBuilds) builds"))
        fields.append(("Apps", "\(status.appCount)"))
        if let hint = status.hint {
            fields.append(("Hint", hint))
        }
        return CLIText.fields(fields)
    }

    private func refresh(_ refresh: RefreshOutput) -> [String] {
        var line: String
        switch (refresh.accepted, refresh.reason, refresh.outcome) {
        case (true, _, let outcome?): line = "Sync finished: \(outcome)."
        case (true, _, nil): line = "Sync started."
        case (false, IPCRefreshReason.recent?, _): line = "Cumulus synced less than \(Int(AppIPCRefresh.recentSync)) seconds ago: nothing to refresh."
        case (false, IPCRefreshReason.syncing?, _): line = refresh.waited ? "A sync was already running: it has finished." : "A sync is already running."
        default: line = "Cumulus did not start a sync."
        }
        if refresh.appLaunched {
            line = "Cumulus was not running: it has been started. " + line
        }
        return [line + "\n"] + (refresh.status.map { [status($0)] } ?? [])
    }

    private func launch(_ launch: LaunchOutput) -> [String] {
        let source = launch.source.pullRequestNumber.map { "PR #\($0)" } ?? launch.source.name ?? ""
        var line = "Started \(launch.reference ?? launch.app) · \(launch.workflow) · \(source)."
        if launch.appLaunched {
            line = "Cumulus was not running: it has been started. " + line
        }
        // Apple accepted the launch but the run is not listed yet: there is nothing to follow it by.
        guard launch.reference != nil || !launch.buildRunID.isEmpty else {
            return [line + "\n", "It is not in the list yet. See it with: cumulus refresh --wait, then cumulus builds --limit 1\n"]
        }
        return [line + "\n", "Follow it with: cumulus build \(launch.reference ?? launch.buildRunID)\n"]
    }

    private func testFlightFields(_ build: TestFlightOutput.Build) -> [(String, String)] {
        var status = build.status
        if let days = build.daysLeft {
            status += ", expires in \(days) day\(days == 1 ? "" : "s")"
        }
        var fields: [(String, String)] = [("TestFlight", "\(build.label)  \(status)")]
        if let uploaded = build.uploadedDate {
            fields.append(("Uploaded", CLIText.date(uploaded, calendar: calendar)))
        }
        if let expiration = build.expirationDate {
            fields.append(("Expires", CLIText.date(expiration, calendar: calendar)))
        }
        fields.append(("Internal", build.internalState))
        fields.append(("External", build.externalState))
        if let review = build.betaReview {
            fields.append(("Beta review", review))
        }
        if let notifies = build.notifiesTesters {
            fields.append(("Notifies testers", notifies ? "yes" : "no"))
        }
        if build.needsExportCompliance {
            fields.append(("Note", "Apple waits for the answer about encryption before any tester gets this build."))
        }
        return fields
    }

    private func testFlight(_ output: TestFlightOutput) -> [String] {
        var fields: [(String, String)] = [("Build", output.reference ?? output.buildRunID), ("App", output.app)]
        fields += output.build.map(testFlightFields) ?? [("TestFlight", "no build known")]
        var sections = [CLIText.fields(fields)]
        if let groups = output.groups {
            var table = CLITable(headers: ["GROUP", "KIND", "TESTERS", "HAS BUILD"], rightAligned: [2], uncut: [0])
            table.rows = groups.map { group in
                [
                    group.name, group.kind, group.testerCount.map(String.init) ?? "-",
                    group.hasBuild ? (group.receivesEveryBuild ? "yes (always)" : "yes") : "-",
                ]
            }
            sections.append(groups.isEmpty ? "No group.\n" : table.render(width: width))
        }
        if let hint = output.hint {
            sections.append(hint + "\n")
        }
        return sections
    }

    private func testFlightChange(_ change: TestFlightChangeOutput) -> [String] {
        let label = change.build?.label
        let build = [change.app, label].compactMap(\.self).joined(separator: " ")
        var lines: [String] = []
        if change.action == "expire" {
            lines.append(change.changed ? "Expired \(build.isEmpty ? change.app : build)." : "Nothing to do: \(build.isEmpty ? change.app : build) is already expired.")
        } else if change.changed {
            if let added = change.added, !added.isEmpty { lines.append("Gave \(build) to \(CLITestFlightWords.list(added)).") }
            if let removed = change.removed, !removed.isEmpty { lines.append("Took \(build) from \(CLITestFlightWords.list(removed)).") }
            if let steps = change.steps, steps.contains("betaReview") { lines.append("Sent the build to Apple's beta review.") }
            if lines.isEmpty { lines.append("Changed \(build).") }
        } else {
            lines.append("Nothing to change: the groups are already as asked.")
        }
        if let unchanged = change.unchanged, !unchanged.isEmpty, change.changed {
            lines.append("Already as asked: \(CLITestFlightWords.list(unchanged)).")
        }
        if change.appLaunched {
            lines[0] = "Cumulus was not running: it has been started. " + lines[0]
        }
        var sections = [lines.joined(separator: "\n") + "\n"]
        if let message = change.message {
            sections.append(message + "\n")
        }
        if change.changed, change.build == nil {
            sections.append("The new state could not be read back. See it with: cumulus testflight \(change.reference ?? change.buildRunID)\n")
        } else if let build = change.build {
            sections.append(CLIText.fields(testFlightFields(build)))
        }
        return sections
    }

    private func usage(_ usage: UsageReportOutput) -> [String] {
        guard let summary = usage.summary else { return [(usage.hint ?? "No plan is set.") + "\n"] }
        var fields = usageFields(summary)
        if let costliest = usage.costliestBuild {
            fields.append(("Costliest", "\(costliest.reference) \(CLIText.minutes(costliest.minutes, estimated: costliest.isEstimated))" + (costliest.workflow.map { " (\($0))" } ?? "")))
        }
        var sections = [CLIText.fields(fields)]
        if let byApp = usage.byApp {
            var table = CLITable(headers: ["APP", "BILLED", "ESTIMATED", "TOTAL"], rightAligned: [1, 2, 3])
            table.rows = byApp.map {
                [$0.app, CLIText.minutes($0.billedMinutes), CLIText.minutes($0.estimatedMinutes, estimated: $0.estimatedMinutes > 0), CLIText.minutes($0.totalMinutes, estimated: $0.estimatedMinutes > 0)]
            }
            sections.append(table.render(width: width))
        }
        if let byWorkflow = usage.byWorkflow {
            var table = CLITable(headers: ["APP", "WORKFLOW", "BUILDS", "AVERAGE", "TOTAL"], rightAligned: [2, 3, 4])
            table.rows = byWorkflow.map {
                [$0.app, $0.workflow, "\($0.buildCount)", CLIText.minutes($0.averageMinutes, estimated: $0.estimatedMinutes > 0), CLIText.minutes($0.totalMinutes, estimated: $0.estimatedMinutes > 0)]
            }
            sections.append(table.render(width: width))
        }
        if let daily = usage.daily {
            var table = CLITable(headers: ["DAY", "BILLED", "ESTIMATED", "TOTAL"], rightAligned: [1, 2, 3])
            table.rows = daily.filter { $0.totalMinutes > 0 }.map {
                [$0.day, CLIText.minutes($0.billedMinutes), CLIText.minutes($0.estimatedMinutes, estimated: $0.estimatedMinutes > 0), CLIText.minutes($0.totalMinutes, estimated: $0.estimatedMinutes > 0)]
            }
            sections.append(table.rows.isEmpty ? "No minutes in the last 30 days.\n" : table.render(width: width))
        }
        return sections
    }

    // MARK: - Lists

    private func accounts(_ accounts: [AccountOutput]) -> String {
        var table = CLITable(headers: ["ACCOUNT", "SHOWN", "APPS", "LAST SYNC"], rightAligned: [2], uncut: [0])
        table.rows = accounts.map { account in
            [
                account.name, account.selected ? "yes" : "-", "\(account.appCount)",
                account.lastSuccessfulSync.map { CLIText.age(since: $0, now: now) } ?? "never",
            ]
        }
        return table.render(width: width)
    }

    private func apps(_ apps: [AppOutput]) -> String {
        guard !apps.isEmpty else { return "No app in the cache.\n" }
        var table = CLITable(headers: ["APP", "BUNDLE ID", "LATEST", "STATUS", "FINISHED", "RUNNING", "CYCLE"], rightAligned: [5, 6], uncut: [0])
        table.rows = apps.map { app in
            [
                app.name, app.bundleID ?? "-", app.latestBuild?.number.map { "#\($0)" } ?? "-", app.latestBuild?.status ?? "-",
                app.latestBuild?.finishedDate.map { CLIText.date($0, calendar: calendar) } ?? "-", "\(app.runningBuilds)",
                app.cycle.map { CLIText.minutes($0.totalMinutes, estimated: $0.estimatedMinutes > 0) } ?? "-",
            ]
        }
        return table.render(width: width)
    }

    private func minutes(of build: BuildOutput) -> String {
        if let billed = build.billedMinutes { return CLIText.minutes(billed) }
        if let estimated = build.estimatedMinutes { return CLIText.minutes(estimated, estimated: true) }
        return "-"
    }

    private func source(of build: BuildOutput) -> String {
        guard let source = build.source else { return "-" }
        if let number = source.pullRequestNumber {
            return "PR #\(number)" + (source.name.map { " \($0)" } ?? "")
        }
        return source.name ?? "-"
    }

    private func builds(_ builds: [BuildOutput]) -> String {
        guard !builds.isEmpty else { return "No build matches.\n" }
        var table = CLITable(headers: ["BUILD", "WORKFLOW", "SOURCE", "STATUS", "CREATED", "DURATION", "MINUTES"], rightAligned: [5, 6], uncut: [0])
        table.rows = builds.map { build in
            [
                build.reference ?? build.id, build.workflow ?? "-", source(of: build), build.status,
                build.createdDate.map { CLIText.date($0, calendar: calendar) } ?? "-",
                build.durationSeconds.map(CLIText.duration) ?? "-", minutes(of: build),
            ]
        }
        return table.render(width: width)
    }

    private func workflows(_ workflows: [WorkflowOutput]) -> String {
        guard !workflows.isEmpty else { return "No workflow in the cache.\n" }
        var table = CLITable(headers: ["APP", "WORKFLOW", "ENABLED", "DEVICES", "LAST BUILD", "STATUS", "BUILDS", "AVERAGE", "TOTAL"], rightAligned: [3, 6, 7, 8])
        table.rows = workflows.map { workflow in
            let estimated = (workflow.cycle?.estimatedMinutes ?? 0) > 0
            return [
                workflow.app ?? "-", workflow.name, workflow.isEnabled.map { $0 ? "yes" : "no" } ?? "-", "\(workflow.testDestinations)",
                workflow.lastBuild?.number.map { "#\($0)" } ?? "-", workflow.lastBuild?.status ?? "-",
                workflow.cycle.map { "\($0.buildCount)" } ?? "-",
                workflow.cycle.map { CLIText.minutes($0.averageMinutes, estimated: estimated) } ?? "-",
                workflow.cycle.map { CLIText.minutes($0.totalMinutes, estimated: estimated) } ?? "-",
            ]
        }
        return table.render(width: width)
    }

    // MARK: - One build

    private func location(_ file: FileOutput?) -> String {
        guard let path = file?.path else { return "-" }
        return file?.line.map { "\(path):\($0)" } ?? path
    }

    private func build(_ detail: BuildDetailOutput) -> [String] {
        let build = detail.build
        var fields: [(String, String)] = [
            ("Build", (build.reference ?? build.id) + "  \(build.status)"),
            ("Workflow", build.workflow ?? "-"),
            ("Source", source(of: build)),
        ]
        if let commit = build.commit, commit.shortSha != nil || commit.message != nil {
            fields.append(("Commit", [commit.shortSha, commit.message.map { CLITable.fit($0, to: 72) }, commit.author.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")))
        }
        if let created = build.createdDate {
            fields.append(("Created", CLIText.date(created, calendar: calendar)))
        }
        if let duration = build.durationSeconds {
            fields.append(("Duration", CLIText.duration(seconds: duration)))
        }
        fields.append(("Minutes", minutes(of: build)))
        if let reason = build.startReason {
            fields.append(("Started by", reason.lowercased().replacing("_", with: " ")))
        }
        fields.append(("Run id", build.id))
        fields.append(("Link", detail.links.appStoreConnect.absoluteString))
        var sections = [CLIText.fields(fields)]

        if !detail.actions.isEmpty {
            var table = CLITable(headers: ["ACTION", "TYPE", "STATUS", "DURATION", "ERRORS", "WARNINGS", "TEST FAILURES"], rightAligned: [3, 4, 5, 6])
            table.rows = detail.actions.map { action in
                [
                    action.name ?? action.id, action.type?.lowercased() ?? "-", action.status, action.durationSeconds.map(CLIText.duration) ?? "-",
                    "\(action.issueCounts?.errors ?? 0)", "\(action.issueCounts?.warnings ?? 0)", "\(action.issueCounts?.testFailures ?? 0)",
                ]
            }
            sections.append(table.render(width: width))
        }
        let devices = detail.actions.flatMap { $0.testDevices ?? [] }
        if !devices.isEmpty {
            var table = CLITable(headers: ["DEVICE", "OS", "TESTS", "FAILED", "TIME"], rightAligned: [2, 3, 4])
            table.rows = devices.map { [$0.deviceName, $0.osVersion, "\($0.testCount)", "\($0.failedCount)", CLIText.duration(seconds: $0.seconds)] }
            sections.append(table.render(width: width))
        }
        if !detail.issues.isEmpty {
            var table = CLITable(headers: ["ISSUE", "MESSAGE", "FILE"])
            table.rows = detail.issues.map { [$0.type.lowercased().replacing("_", with: " "), $0.message ?? "-", location($0.file)] }
            var text = table.render(width: width)
            if detail.omittedWarnings > 0 {
                text += "… and \(detail.omittedWarnings) more warnings: open the build in Cumulus to see them all.\n"
            }
            sections.append(text)
        }
        if !detail.failedTests.isEmpty {
            var table = CLITable(headers: ["FAILED TEST", "MESSAGE", "DEVICES"])
            table.rows = detail.failedTests.map { test in
                [
                    [test.className, test.name].compactMap(\.self).joined(separator: "."), test.message ?? "-",
                    test.devices.filter { $0.status == "FAILURE" || $0.status == "MIXED" }.map(\.deviceName).joined(separator: ", "),
                ]
            }
            sections.append(table.render(width: width))
        }
        if let summary = detail.testSummary, summary.total > 0 {
            sections.append("Tests: \(summary.total) run, \(summary.failed) failed, \(summary.skipped) skipped.\n")
        }
        if !detail.artifacts.isEmpty {
            var table = CLITable(headers: ["ARTIFACT", "TYPE", "SIZE"], rightAligned: [2])
            table.rows = detail.artifacts.map { [$0.fileName ?? "-", $0.fileType?.lowercased().replacing("_", with: " ") ?? "-", $0.fileSize.map(CLIText.fileSize) ?? "-"] }
            sections.append(table.render(width: width))
        }
        if !detail.testFlightBuilds.isEmpty {
            sections.append(detail.testFlightBuilds.map { "TestFlight build \($0.version ?? $0.id): \($0.processingState?.lowercased() ?? "unknown")" }.joined(separator: "\n") + "\n")
        }
        if let hint = detail.hint {
            sections.append(hint + "\n")
        }
        return sections
    }
}
