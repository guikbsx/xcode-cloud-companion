import Foundation
import Testing
@testable import XcodeCloudCompanion

struct AgentLinkTests {
    private let fileManager = FileManager.default

    /// A stand-in for the app bundle and a folder to link from, both in a temporary place.
    private func setUp(bundleName: String = "Cumulus.app") throws -> (locations: AgentLocations, folder: URL) {
        let root = fileManager.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundle = root.appending(path: "Applications/\(bundleName)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: bundle.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle.appending(path: "Contents/Resources/AgentSkill/cumulus"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bundle.appending(path: "Contents/Helpers/cumulus"))
        let folder = root.appending(path: "bin", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return (AgentLocations(bundle: bundle, home: root.appending(path: "home", directoryHint: .isDirectory)), folder)
    }

    @Test func aLinkIsCreatedSeenAndRemoved() async throws {
        let (locations, folder) = try setUp()
        let link = locations.commandLink(in: folder)

        #expect(await link.state() == .missing)
        try await link.install()
        #expect(await link.state() == .installed)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: folder.appending(path: "cumulus").path(percentEncoded: false))
            == locations.command.path(percentEncoded: false))
        try await link.install()
        #expect(await link.state() == .installed)

        try await link.remove()
        #expect(await link.state() == .missing)
        try await link.remove()
    }

    @Test func aLinkToAMovedAppIsBrokenAndRepaired() async throws {
        let (locations, folder) = try setUp()
        try await locations.commandLink(in: folder).install()
        var moved = locations
        moved.bundle = locations.bundle.deletingLastPathComponent().appending(path: "Elsewhere/Cumulus.app", directoryHint: .isDirectory)
        let link = moved.commandLink(in: folder)

        #expect(await link.state() == .broken)
        try await link.install()
        #expect(await link.state() == .installed)
        #expect(await locations.commandLink(in: folder).state() == .broken)
    }

    @Test func whatIsNotOursIsLeftAlone() async throws {
        let (locations, folder) = try setUp()
        let link = locations.commandLink(in: folder)
        try Data("mine".utf8).write(to: link.url)

        #expect(await link.state() == .occupied)
        await #expect(throws: AgentLinkError.occupied) { try await link.install() }
        await #expect(throws: AgentLinkError.occupied) { try await link.remove() }
        #expect(try String(contentsOf: link.url, encoding: .utf8) == "mine")

        try fileManager.removeItem(at: link.url)
        try fileManager.createSymbolicLink(atPath: link.url.path(percentEncoded: false), withDestinationPath: "/usr/bin/true")
        #expect(await link.state() == .occupied)
    }

    @Test func theSkillIsAFolderLinkedTheSameWay() async throws {
        let (locations, folder) = try setUp()
        let link = locations.skillLink(in: folder)

        try await link.install()

        #expect(await link.state() == .installed)
        #expect(link.url.lastPathComponent == "cumulus")
        #expect(locations.skill.path(percentEncoded: false).hasSuffix("Cumulus.app/Contents/Resources/AgentSkill/cumulus/"))
    }

    @Test func aFolderThatCannotBeWrittenSaysWhy() async throws {
        let (locations, _) = try setUp()
        let nowhere = fileManager.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        do {
            try await locations.commandLink(in: nowhere).install()
            Issue.record("the link should not have been created")
        } catch {
            guard case .refused = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(!error.message.isEmpty)
        }
    }
}

struct AgentClientTests {
    private let command = URL(filePath: "/Applications/Cumulus.app/Contents/Helpers/cumulus")

    @Test func commandLineClientsGetACommand() {
        #expect(AgentClient.claudeCode.snippet(command: command) == "claude mcp add --scope user cumulus -- /Applications/Cumulus.app/Contents/Helpers/cumulus mcp")
        #expect(AgentClient.codex.snippet(command: command) == "codex mcp add cumulus -- /Applications/Cumulus.app/Contents/Helpers/cumulus mcp")
        #expect(AgentClient.claudeCode.configurationFile == nil && AgentClient.codex.configurationFile == nil)
    }

    @Test func aPathWithASpaceIsQuoted() {
        let spaced = URL(filePath: "/Users/me/My Apps/Cumulus.app/Contents/Helpers/cumulus")

        #expect(AgentClient.codex.snippet(command: spaced) == "codex mcp add cumulus -- '/Users/me/My Apps/Cumulus.app/Contents/Helpers/cumulus' mcp")
        #expect(AgentClient.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(AgentClient.shellQuoted("/opt/homebrew/bin/cumulus") == "/opt/homebrew/bin/cumulus")
    }

    @Test func configurationFileClientsGetAnEntryToMerge() throws {
        for client in [AgentClient.xcode, .claudeDesktop] {
            let entry = try #require(JSONValue(data: Data(client.snippet(command: command).utf8)))
            #expect(entry == ["mcpServers": ["cumulus": ["command": "/Applications/Cumulus.app/Contents/Helpers/cumulus", "args": ["mcp"]]]])
            #expect(!client.compactSnippet(command: command).contains("\n"))
        }
        #expect(AgentClient.xcode.configurationFile == "~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json")
        #expect(AgentClient.claudeDesktop.configurationFile == "~/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(AgentClient.allCases.map(\.name) == ["Claude Code", "Codex", "Xcode", "Claude Desktop"])
    }

    @Test func foldersOfTheHomeAreShownWithATilde() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let locations = AgentLocations(bundle: URL(filePath: "/Applications/Cumulus.app"), home: home)

        #expect(locations.abbreviated(URL(filePath: "/Users/me/.claude/skills", directoryHint: .isDirectory)) == "~/.claude/skills")
        #expect(locations.abbreviated(URL(filePath: "/opt/homebrew/bin/", directoryHint: .isDirectory)) == "/opt/homebrew/bin")
        #expect(locations.abbreviated(URL(filePath: "/Users/merlin/bin")) == "/Users/merlin/bin")
        #expect(AgentSkillHost.known.map { $0.directory(home: home).path(percentEncoded: false) } == ["/Users/me/.claude/skills/", "/Users/me/.codex/skills/"])
    }
}

@MainActor
struct AgentsSettingsModelTests {
    private let fileManager = FileManager.default

    private func setUp() throws -> (model: AgentsSettingsModel, locations: AgentLocations, bin: URL, defaults: UserDefaults) {
        let root = fileManager.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundle = root.appending(path: "Cumulus.app", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        for directory in [bundle.appending(path: "Contents/Helpers"), bundle.appending(path: "Contents/Resources/AgentSkill/cumulus"), home.appending(path: ".claude/skills"), bin] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let locations = AgentLocations(bundle: bundle, home: home)
        let defaults = try #require(UserDefaults(suiteName: "agents-\(UUID().uuidString)"))
        return (AgentsSettingsModel(locations: locations, defaults: defaults), locations, bin, defaults)
    }

    @Test func nothingIsInstalledAtFirst() async throws {
        let (model, _, _, _) = try setUp()

        await model.refresh()

        #expect(model.commandState == .missing && model.commandDirectory == nil && model.errorMessage == nil)
        #expect(model.skills.map(\.name) == ["Claude Code", "Codex"])
        #expect(model.skills.map(\.directoryExists) == [true, false])
        #expect(model.skills.allSatisfy { $0.state == .missing })
    }

    @Test func eachAgentListsWhatItNeedsAndTheMCPServerIsNeverCounted() async throws {
        let (model, locations, bin, _) = try setUp()
        await model.refresh()

        #expect(AgentClient.allCases.map(\.keepsSkills) == [true, true, false, false], "Claude Code and Codex keep skills; Xcode and Claude Desktop only speak MCP")
        #expect(model.checklist(for: .claudeCode).skills.map(\.name) == ["Claude Code"])
        #expect(model.checklist(for: .codex).skills.map(\.name) == ["Codex"])
        #expect(model.checklist(for: .claudeCode).done == 0 && model.checklist(for: .claudeCode).total == 2)
        #expect(model.checklist(for: .xcode) == AgentsSettingsModel.Checklist(skills: [], done: 0, total: 1))

        // The command is the same link for every agent.
        await model.installCommand(in: bin)
        #expect(AgentClient.allCases.map { model.checklist(for: $0).done } == [1, 1, 1, 1])
        #expect(model.checklist(for: .claudeDesktop).done == model.checklist(for: .claudeDesktop).total, "nothing more to count: the MCP entry is added by hand")

        await model.installSkill(in: locations.home.appending(path: ".claude/skills", directoryHint: .isDirectory))
        #expect(model.checklist(for: .claudeCode).done == 2 && model.checklist(for: .codex).done == 1)
    }

    @Test func theCommandIsInstalledFoundAgainAndRemoved() async throws {
        let (model, locations, bin, defaults) = try setUp()

        await model.installCommand(in: bin)
        #expect(model.commandState == .installed && model.commandDirectory == bin && model.errorMessage == nil)

        // A new window, later: the folder is remembered, the link is found again.
        let later = AgentsSettingsModel(locations: locations, defaults: defaults)
        await later.refresh()
        #expect(later.commandState == .installed && later.commandDirectory?.path(percentEncoded: false) == bin.path(percentEncoded: false))

        await later.removeCommand()
        #expect(later.commandState == .missing && later.commandDirectory == nil && later.errorMessage == nil)
    }

    @Test func anAppThatMovedShowsItsLinkAsBroken() async throws {
        let (model, locations, bin, defaults) = try setUp()
        await model.installCommand(in: bin)
        var moved = locations
        moved.bundle = locations.bundle.deletingLastPathComponent().appending(path: "Moved/Cumulus.app", directoryHint: .isDirectory)
        let after = AgentsSettingsModel(locations: moved, defaults: defaults)

        await after.refresh()
        #expect(after.commandState == .broken && after.commandDirectory != nil)

        await after.installCommand(in: bin)
        #expect(after.commandState == .installed)
    }

    @Test func aRefusedInstallationIsExplained() async throws {
        let (model, locations, bin, _) = try setUp()
        try Data("mine".utf8).write(to: locations.commandLink(in: bin).url)

        await model.installCommand(in: bin)

        #expect(model.commandState == .missing)
        #expect(model.errorMessage == AgentLinkError.occupied.message)
    }

    @Test func theSkillGoesIntoAnAgentsFolderOrAnyOther() async throws {
        let (model, locations, bin, defaults) = try setUp()
        let claude = AgentSkillHost.known[0].directory(home: locations.home)

        await model.installSkill(in: claude)
        #expect(model.skills.first?.state == .installed && model.skills.count == 2)

        await model.installSkill(in: bin)
        #expect(model.skills.count == 3 && model.skills.last?.state == .installed)
        #expect(model.skills.last?.directory.path(percentEncoded: false) == bin.path(percentEncoded: false))
        let later = AgentsSettingsModel(locations: locations, defaults: defaults)
        await later.refresh()
        #expect(later.skills.map(\.state) == [.installed, .missing, .installed])

        await later.removeSkill(in: bin)
        await later.removeSkill(in: claude)
        #expect(later.skills.map(\.state) == [.missing, .missing])
    }
}

struct AgentSkillBundleTests {
    private func skillFile(_ name: String) throws -> String {
        let folder = try #require(Bundle.main.url(forResource: "AgentSkill", withExtension: nil))
        return try String(contentsOf: folder.appending(path: "cumulus/\(name)"), encoding: .utf8)
    }

    @Test func theSkillShipsInTheBundleWithItsFrontmatter() throws {
        let skill = try skillFile("SKILL.md")
        let lines = skill.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "---" && lines[1] == "name: cumulus" && lines[2].hasPrefix("description: ") && lines[3] == "---")
        #expect(lines[2].count > 200 && lines[2].contains("Xcode Cloud"))
        #expect(AgentLocations.live.skill.path(percentEncoded: false).hasSuffix("Contents/Resources/AgentSkill/cumulus/"))
    }

    /// The skill is what agents read instead of the code: it has to name what the code really offers.
    @Test func theSkillNamesEveryCommandToolAndErrorCode() throws {
        let skill = try skillFile("SKILL.md")
        let contract = try skillFile("references/output-contract.md")

        for command in CLIParser.commandNames where !["help", "version"].contains(command) {
            #expect(skill.contains("cumulus \(command)"), "SKILL.md does not mention 'cumulus \(command)'")
        }
        for tool in MCPTools.all {
            #expect(skill.contains("`\(tool.name)`") && contract.contains("`\(tool.name)`"), "\(tool.name) is missing from the skill")
            for argument in tool.allProperties.keys {
                #expect(contract.contains("`\(argument)`"), "argument \(argument) of \(tool.name) is missing from the contract")
            }
        }
        for code in ["NOT_FOUND", "AMBIGUOUS", "NO_CACHE", "USAGE", "INTERNAL", "APP_UNREACHABLE", "TIMEOUT"] {
            #expect(CLIErrorCode(rawValue: code) != nil && contract.contains("`\(code)`"))
        }
        #expect(skill.contains("`--account <name>`") && skill.contains("`meta.account`"))
        for key in ["lastSuccessfulSync", "appRunning", "isEstimate", "account", "selected", "detailsAvailable", "omittedWarnings", "estimatedMinutes", "billedMinutes"] {
            #expect(contract.contains("`\(key)`"))
        }
    }

    @Test func helpSaysWhereTheCommandIsInstalledFrom() {
        #expect(CLIHelp.overview.hasSuffix("Install this command and its agent skill from Cumulus › Settings › Agents.\n"))
    }
}
