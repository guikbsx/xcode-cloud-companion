import Foundation

/// The preferences that belong to one account: each key carries the account's id, so two accounts never read each other's plan.
nonisolated enum AccountDefaults {
    static let planHours = "plan.hours"
    static let resetAnchor = "plan.resetAnchor"
    static let keyAccess = "keyAccess"
    static let palette = "appPalette.assignments"
    static let usageAlertState = "notifications.usage.alertState"
    static let reportedStuckRunIDs = "notifications.builds.reportedStuckRunIDs"
    /// The build that starts each workflow's slowdown already reported, by workflow ID.
    static let reportedSlowdowns = "notifications.builds.reportedSlowdowns"
    /// What was said of each app's TestFlight builds (a build reaching external testers, a coming expiry), by Xcode Cloud product.
    static let testFlightAlertState = "notifications.testFlight.alertState"
    /// The events sent to the account's webhook (the address itself is in the keychain, never here).
    static let webhookEvents = "webhook.events"
    /// What the account's webhook was already told of the plan in the cycle: kept apart from the banners, which have their own.
    static let webhookUsageAlertState = "webhook.usageAlertState"
    /// Security-scoped bookmarks of the apps' local clones, by product name.
    static let localRepositories = "localRepositories"

    /// Every name an account has its own value for.
    static let names = [planHours, resetAnchor, keyAccess, palette, usageAlertState, reportedStuckRunIDs, reportedSlowdowns, testFlightAlertState, webhookEvents, webhookUsageAlertState, localRepositories]

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
