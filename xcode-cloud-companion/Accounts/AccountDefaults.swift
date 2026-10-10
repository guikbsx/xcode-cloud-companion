import Foundation

/// The preferences that belong to one account: each key carries the account's id, so two accounts never read each other's plan.
nonisolated enum AccountDefaults {
    static let planHours = "plan.hours"
    static let resetAnchor = "plan.resetAnchor"
    static let keyAccess = "keyAccess"
    static let palette = "appPalette.assignments"
    static let usageAlertState = "notifications.usage.alertState"
    static let reportedStuckRunIDs = "notifications.builds.reportedStuckRunIDs"

    /// Every name an account has its own value for.
    static let names = [planHours, resetAnchor, keyAccess, palette, usageAlertState, reportedStuckRunIDs]

    static func key(_ name: String, accountID: String) -> String {
        "account.\(accountID).\(name)"
    }

    /// Hands the first account the values saved before accounts existed, once: a value it already has is kept.
    static func adoptLegacyValues(in defaults: UserDefaults, accountID: String = AccountRegistry.firstAccountID) {
        for name in names {
            guard let value = defaults.object(forKey: name) else { continue }
            let key = key(name, accountID: accountID)
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.removeObject(forKey: name)
        }
    }

    static func removeAll(accountID: String, from defaults: UserDefaults) {
        for name in names {
            defaults.removeObject(forKey: key(name, accountID: accountID))
        }
    }
}
