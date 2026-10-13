import Foundation

/// The kind of a failed build, decided by rules on what Apple reported, never by the language model.
nonisolated enum FailureCategory: String, Codable, Sendable, CaseIterable {
    case compilation
    case tests
    case flakyTest
    case signing
    case configuration
    case distribution
    case infrastructure
    case other

    static let signingMarkers = [
        "code sign", "codesign", "provisioning", "signing certificate", "signing identity", "development team",
        "signing for", "no profile", "certificate", "entitlement",
    ]

    /// Nil while the build's issues or test results are not loaded: the rules would be guessing.
    init?(prompt: BuildFailurePrompt) {
        guard prompt.hasIssues, prompt.hasTests else { return nil }
        self = Self.decide(completion: prompt.run.completionStatus, errors: prompt.errors, failedTests: prompt.failedTests)
    }

    static func decide(completion: CICompletionStatus?, errors: [CIIssue], failedTests: [CITestResult]) -> FailureCategory {
        if errors.contains(where: { isSigning($0.message) }) { return .signing }
        if errors.contains(where: { hasSourceFile($0) || isCompilerStep($0) }) { return .compilation }
        if !errors.isEmpty { return errors.allSatisfy(isDistributionStep) ? .distribution : .configuration }
        if !failedTests.isEmpty { return failedTests.allSatisfy { $0.status == .mixed } ? .flakyTest : .tests }
        return completion == .errored ? .infrastructure : .other
    }

    private static func isSigning(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return signingMarkers.contains { message.contains($0) }
    }

    private static let distributionSteps = ["exportarchive", "preparebuildforappstoreconnect", "upload", "distribut"]

    private static func isCompilerStep(_ issue: CIIssue) -> Bool {
        issue.category?.lowercased().contains("xcodebuild") == true
    }

    private static func isDistributionStep(_ issue: CIIssue) -> Bool {
        guard let category = issue.category?.lowercased() else { return false }
        return distributionSteps.contains { category.contains($0) }
    }

    private static func hasSourceFile(_ issue: CIIssue) -> Bool {
        issue.file?.path?.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    var displayName: String {
        switch self {
        case .compilation: String(localized: "Compilation", comment: "Category of a failed build: the code does not compile")
        case .tests: String(localized: "Tests", comment: "Category of a failed build: tests failed")
        case .flakyTest: String(localized: "Flaky Test", comment: "Category of a failed build: tests that both passed and failed")
        case .signing: String(localized: "Signing", comment: "Category of a failed build: code signing or provisioning")
        case .configuration: String(localized: "Configuration", comment: "Category of a failed build: the workflow or project is misconfigured")
        case .distribution: String(localized: "Distribution", comment: "Category of a failed build: exporting or uploading the build failed")
        case .infrastructure: String(localized: "Infrastructure", comment: "Category of a failed build: Xcode Cloud or the build machine failed")
        case .other: String(localized: "Other", comment: "Category of a failed build with no clear cause")
        }
    }
}
