import Foundation

// The shapes below are the command's public contract: their property names are the JSON keys agents read.

nonisolated struct UsageOutput: Equatable, Sendable, Encodable {
    struct Measurement: Equatable, Sendable, Encodable {
        var isMeasuring: Bool
        var pendingBuilds: Int
        var measuredActions: Int
        var totalActions: Int
        var unmeasurableActions: Int
    }

    var planHours: Int
    var quotaMinutes: Double
    var billedMinutes: Double
    var estimatedMinutes: Double
    var usedMinutes: Double
    var remainingMinutes: Double
    var fractionUsed: Double
    var cycleStart: Date
    var resetDate: Date
    var projectedMinutes: Double?
    var exhaustionDate: Date?
    var estimatedBuildCount: Int
    var lastImport: Date?
    var importIsStale: Bool
    var measurement: Measurement
    var note: String?
}

nonisolated struct StatusOutput: Equatable, Sendable, Encodable {
    var planConfigured: Bool
    var usage: UsageOutput?
    var runningBuilds: Int
    var appCount: Int
    var hint: String?
}

nonisolated struct MinutesOutput: Equatable, Sendable, Encodable {
    var billedMinutes: Double
    var estimatedMinutes: Double
    var totalMinutes: Double
}

nonisolated struct BuildBrief: Equatable, Sendable, Encodable {
    var id: String
    var reference: String?
    var number: Int?
    var status: String
    var createdDate: Date?
    var finishedDate: Date?
}

nonisolated struct AppOutput: Equatable, Sendable, Encodable {
    var id: String
    var name: String
    /// The app's App Store name; nil for a product that is not an app. `name` stays the product name, the one `--app` and references use.
    var storeName: String?
    var bundleID: String?
    var type: String?
    var latestBuild: BuildBrief?
    var runningBuilds: Int
    var cycle: MinutesOutput?
}

nonisolated struct BuildOutput: Equatable, Sendable, Encodable {
    struct Source: Equatable, Sendable, Encodable {
        var kind: String
        var name: String?
        var pullRequestNumber: Int?
        var pullRequestTitle: String?
    }

    struct Commit: Equatable, Sendable, Encodable {
        var sha: String?
        var shortSha: String?
        var message: String?
        var author: String?
        var url: URL?
    }

    var id: String
    var reference: String?
    var app: String
    var productID: String
    var number: Int?
    var workflow: String?
    var workflowID: String?
    var source: Source?
    var status: String
    var executionProgress: String
    var completionStatus: String?
    var startReason: String?
    var cancelReason: String?
    var createdDate: Date?
    var startedDate: Date?
    var finishedDate: Date?
    var durationSeconds: Int?
    var commit: Commit?
    var issueCounts: CIIssueCounts?
    var billedMinutes: Double?
    var estimatedMinutes: Double?
}

nonisolated struct FileOutput: Equatable, Sendable, Encodable {
    var path: String?
    var line: Int?
}

nonisolated struct BuildDetailOutput: Equatable, Sendable, Encodable {
    struct Device: Equatable, Sendable, Encodable {
        var deviceName: String
        var osVersion: String
        var testCount: Int
        var failedCount: Int
        var seconds: Int
    }

    struct Action: Equatable, Sendable, Encodable {
        var id: String
        var name: String?
        var type: String?
        var status: String
        var executionProgress: String
        var completionStatus: String?
        var isRequiredToPass: Bool?
        var startedDate: Date?
        var finishedDate: Date?
        var durationSeconds: Int?
        var issueCounts: CIIssueCounts?
        var testDevices: [Device]?
    }

    struct Issue: Equatable, Sendable, Encodable {
        var actionID: String
        var action: String?
        var type: String
        var category: String?
        var message: String?
        var file: FileOutput?
    }

    struct TestDevice: Equatable, Sendable, Encodable {
        var deviceName: String
        var osVersion: String
        var status: String
        var durationSeconds: Double?
    }

    struct FailedTest: Equatable, Sendable, Encodable {
        var actionID: String
        var className: String?
        var name: String?
        var status: String
        var message: String?
        var file: FileOutput?
        var devices: [TestDevice]
    }

    struct TestSummary: Equatable, Sendable, Encodable {
        var total: Int
        var failed: Int
        var skipped: Int
        var passed: Int
    }

    struct Artifact: Equatable, Sendable, Encodable {
        var actionID: String
        var fileName: String?
        var fileType: String?
        var fileSize: Int?
    }

    struct TestFlightBuild: Equatable, Sendable, Encodable {
        var id: String
        var version: String?
        var uploadedDate: Date?
        var processingState: String?
    }

    struct Links: Equatable, Sendable, Encodable {
        var appStoreConnect: URL
        var cumulus: String
    }

    struct Loaded: Equatable, Sendable, Encodable {
        var issues: Bool
        var tests: Bool
        var artifacts: Bool
    }

    static let maximumWarnings = 50

    var build: BuildOutput
    var actions: [Action]
    var detailsAvailable: Bool
    var detailsLoaded: Loaded
    var issues: [Issue]
    /// Warnings beyond the first fifty are counted, not listed: errors and test failures always are.
    var omittedWarnings: Int
    var failedTests: [FailedTest]
    var testSummary: TestSummary?
    var artifacts: [Artifact]
    var testFlightBuilds: [TestFlightBuild]
    var links: Links
    var hint: String?
}

nonisolated struct WorkflowOutput: Equatable, Sendable, Encodable {
    struct Cycle: Equatable, Sendable, Encodable {
        var buildCount: Int
        var billedMinutes: Double
        var estimatedMinutes: Double
        var totalMinutes: Double
        var averageMinutes: Double
    }

    var id: String
    var name: String
    var app: String?
    var productID: String?
    var isEnabled: Bool?
    var description: String?
    var testDestinations: Int
    var actions: [String]?
    var repository: String?
    var xcodeVersion: String?
    var macOSVersion: String?
    var lastBuild: BuildBrief?
    var cycle: Cycle?
}

nonisolated struct UsageReportOutput: Equatable, Sendable, Encodable {
    struct App: Equatable, Sendable, Encodable {
        var app: String
        var billedMinutes: Double
        var estimatedMinutes: Double
        var totalMinutes: Double
    }

    struct Workflow: Equatable, Sendable, Encodable {
        var app: String
        var workflow: String
        var buildCount: Int
        var billedMinutes: Double
        var estimatedMinutes: Double
        var totalMinutes: Double
        var averageMinutes: Double
    }

    struct Day: Equatable, Sendable, Encodable {
        var day: String
        var billedMinutes: Double
        var estimatedMinutes: Double
        var totalMinutes: Double
    }

    struct CostliestBuild: Equatable, Sendable, Encodable {
        var app: String
        var number: Int
        var reference: String
        var workflow: String?
        var minutes: Double
        var isEstimated: Bool
    }

    var planConfigured: Bool
    var summary: UsageOutput?
    var costliestBuild: CostliestBuild?
    var byApp: [App]?
    var byWorkflow: [Workflow]?
    var daily: [Day]?
    var hint: String?
}

nonisolated struct RefreshOutput: Equatable, Sendable, Encodable {
    var accepted: Bool
    /// Why the app did not start a sync: one is running (`syncing`) or just ended (`recent`).
    var reason: String?
    var outcome: String?
    var waited: Bool
    var appLaunched: Bool
    var status: StatusOutput?
}

nonisolated enum CLIReport: Equatable, Sendable {
    case status(StatusOutput)
    case apps([AppOutput])
    case builds([BuildOutput])
    case build(BuildDetailOutput)
    case workflows([WorkflowOutput])
    case usage(UsageReportOutput)
    case refresh(RefreshOutput)
}

nonisolated struct CLIResponse: Equatable, Sendable {
    var report: CLIReport
    var meta: CLIMeta

    var jsonData: Data {
        switch report {
        case .status(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .apps(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .builds(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .build(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .workflows(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .usage(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        case .refresh(let value): CLIJSON.data(CLIEnvelope(data: value, meta: meta))
        }
    }

    var json: String {
        String(decoding: jsonData, as: UTF8.self) + "\n"
    }
}
