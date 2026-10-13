import Foundation

nonisolated struct WorkflowActionRow: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let kind: String
    let facts: String
}

/// What the workflow sheet shows: its state, how it starts, where it runs and what it does. Unknown means hidden.
nonisolated struct WorkflowDetailModel: Equatable, Sendable {
    let id: String
    let title: String
    let productName: String?
    let description: String?
    let isEnabled: Bool?
    let isLocked: Bool?
    let info: [InfoField]
    let startConditions: [InfoField]
    let actions: [WorkflowActionRow]

    init(workflow: CIWorkflow, productName: String?, locale: Locale = .autoupdatingCurrent) {
        id = workflow.id
        title = workflow.name
        self.productName = productName
        description = workflow.description?.nilIfBlank
        isEnabled = workflow.isEnabled
        isLocked = workflow.isLockedForEditing

        var info: [InfoField] = []
        if let clean = workflow.clean {
            info.append(InfoField(title: String(localized: "Clean build"), value: clean ? String(localized: "Yes") : String(localized: "No")))
        }
        if let path = workflow.containerFilePath?.nilIfBlank {
            info.append(InfoField(title: String(localized: "Project"), value: path))
        }
        if let repository = workflow.repositoryName?.nilIfBlank {
            info.append(InfoField(title: String(localized: "Repository"), value: repository))
        }
        if let xcode = workflow.xcodeVersionName?.nilIfBlank {
            info.append(InfoField(title: "Xcode", value: xcode))
        }
        if let macOS = workflow.macOSVersionName?.nilIfBlank {
            info.append(InfoField(title: "macOS", value: macOS))
        }
        if let modified = workflow.lastModifiedDate {
            info.append(InfoField(title: String(localized: "Last modified"), value: UsageFormat.moment(modified, locale: locale)))
        }
        self.info = info

        startConditions = Self.conditions(workflow.startConditions)
        actions = workflow.actions.enumerated().map { index, action in
            WorkflowActionRow(
                id: index,
                name: action.name?.nilIfBlank ?? Self.kind(of: action.actionType),
                kind: Self.kind(of: action.actionType),
                facts: UsageFormat.dotted([
                    action.platform.map(Self.label(of:)), action.destination?.nilIfBlank, action.scheme?.nilIfBlank,
                    action.buildDistributionAudience?.nilIfBlank.map(Self.audience),
                    action.isRequiredToPass == true ? String(localized: "Required") : nil,
                ].compactMap(\.self))
            )
        }
    }

    /// The facts and the conditions of the sheet's skeleton: their titles are the real ones, their values only a length.
    static let placeholderInfo = [
        InfoField(title: String(localized: "Project"), value: "Cumulus.xcodeproj"),
        InfoField(title: String(localized: "Repository"), value: "xcode-cloud-companion"),
        InfoField(title: "Xcode", value: "Xcode 27.1"),
        InfoField(title: "macOS", value: "macOS 27.0"),
    ]
    static let placeholderConditions = [
        InfoField(title: String(localized: "Branch changes"), value: "main"),
        InfoField(title: String(localized: "Pull requests"), value: "All"),
        InfoField(title: String(localized: "Auto-cancel"), value: "On"),
    ]
    static let placeholderDescription = "Builds, tests and archives the app, then hands it to TestFlight."

    private static func conditions(_ conditions: CIStartConditions?) -> [InfoField] {
        guard let conditions else { return [] }
        var lines: [InfoField] = []
        func add(_ title: String, _ patterns: CIPatterns?) {
            if let patterns { lines.append(InfoField(title: title, value: describe(patterns))) }
        }
        add(String(localized: "Branch changes"), conditions.branches)
        add(String(localized: "Tag changes"), conditions.tags)
        add(String(localized: "Pull requests"), conditions.pullRequests)
        if let frequency = conditions.scheduleFrequency {
            let value: String = switch frequency {
            case .hourly: String(localized: "Every hour")
            case .daily: String(localized: "Every day")
            case .weekly: String(localized: "Every week")
            }
            lines.append(InfoField(title: String(localized: "Schedule"), value: value))
        }
        if let rule = conditions.filesRule {
            let value: String = switch rule {
            case .startIfAnyFileMatches: String(localized: "Start only if a changed file matches")
            case .doNotStartIfAllFilesMatch: String(localized: "Don’t start if every changed file matches")
            }
            lines.append(InfoField(title: String(localized: "Files and folders"), value: value))
        }
        if let autoCancel = conditions.autoCancel {
            lines.append(InfoField(title: String(localized: "Auto-cancel"), value: autoCancel ? String(localized: "On") : String(localized: "Off")))
        }
        if conditions.allowsManualStart {
            let kinds = [
                conditions.manualBranches == nil ? nil : String(localized: "branches"),
                conditions.manualTags == nil ? nil : String(localized: "tags"),
                conditions.manualPullRequests == nil ? nil : String(localized: "pull requests"),
            ].compactMap(\.self)
            lines.append(InfoField(title: String(localized: "Manual start"), value: kinds.formatted(.list(type: .and, width: .narrow))))
        }
        return lines
    }

    private static func describe(_ patterns: CIPatterns) -> String {
        if patterns.isAllMatch { return String(localized: "All") }
        return patterns.patterns.isEmpty ? String(localized: "None") : patterns.patterns.joined(separator: ", ")
    }

    private static func kind(of type: CIActionType?) -> String {
        switch type {
        case .build?: String(localized: "Build")
        case .analyze?: String(localized: "Analyze")
        case .test?: String(localized: "Test")
        case .archive?: String(localized: "Archive")
        default: "?"
        }
    }

    private static func label(of platform: CIPlatform) -> String {
        switch platform {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        case .visionOS: "visionOS"
        }
    }

    private static func audience(_ raw: String) -> String {
        switch raw {
        case "INTERNAL_ONLY": String(localized: "TestFlight internal testing")
        case "APP_STORE_ELIGIBLE": String(localized: "TestFlight and App Store")
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
