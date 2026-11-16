import Foundation
import FoundationModels

/// Whether the failure summary exists at all: the model must be there, and the user must want it.
/// Views and stores ask here and nowhere else.
nonisolated enum FailureInsightFeature {
    static let settingKey = "failureInsight.enabled"

    enum ModelStatus: Equatable, Sendable {
        case available, deviceNotEligible, notEnabled, notReady

        init(_ availability: SystemLanguageModel.Availability) {
            switch availability {
            case .available: self = .available
            case .unavailable(.deviceNotEligible): self = .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): self = .notEnabled
            case .unavailable(.modelNotReady): self = .notReady
            case .unavailable: self = .notReady
            }
        }

        static var current: ModelStatus { ModelStatus(SystemLanguageModel.default.availability) }

        /// Why the toggle in Settings is grayed out; nil when the model is there.
        var reason: String? {
            switch self {
            case .available: nil
            case .deviceNotEligible: String(localized: "This Mac does not support Apple Intelligence.")
            case .notEnabled: String(localized: "Apple Intelligence is turned off in System Settings.")
            case .notReady: String(localized: "The Apple Intelligence model is still downloading.")
            }
        }
    }

    enum Mode: Equatable, Sendable {
        /// Nothing is shown, anywhere.
        case hidden
        case open
    }

    static func mode(model: ModelStatus, settingOn: Bool) -> Mode {
        model == .available && settingOn ? .open : .hidden
    }

    static func isSettingOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }
}

nonisolated extension FailureInsightLanguage {
    /// French when the app runs in French and the model writes it, English otherwise.
    init(appLanguage: String?, modelWritesFrench: Bool) {
        self = appLanguage == "fr" && modelWritesFrench ? .french : .english
    }

    static var current: FailureInsightLanguage {
        FailureInsightLanguage(
            appLanguage: Bundle.main.preferredLocalizations.first,
            modelWritesFrench: SystemLanguageModel.default.supportsLocale(FailureInsightLanguage.french.locale)
        )
    }

    var cacheKey: String {
        self == .french ? "fr" : "en"
    }
}
