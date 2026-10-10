import Foundation
import Observation

/// What the Notifications tab of Settings edits; every change is saved at once.
@Observable
final class NotificationPreferences {
    var builds: BuildNotificationRules {
        didSet {
            guard builds != oldValue else { return }
            defaults.set(builds.succeeded, forKey: Keys.succeeded)
            defaults.set(builds.failed, forKey: Keys.failed)
            defaults.set(builds.canceled, forKey: Keys.canceled)
            defaults.set(builds.stuck, forKey: Keys.stuck)
            defaults.set(builds.stuckFactor, forKey: Keys.stuckFactor)
            defaults.set(builds.mutedProductIDs.sorted(), forKey: Keys.mutedProductIDs)
        }
    }

    var usage: UsageAlertRules {
        didSet {
            guard usage != oldValue else { return }
            defaults.set(usage.threshold75, forKey: Keys.threshold75)
            defaults.set(usage.threshold90, forKey: Keys.threshold90)
            defaults.set(usage.pace, forKey: Keys.pace)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var builds = BuildNotificationRules()
        builds.succeeded = defaults.object(forKey: Keys.succeeded) as? Bool ?? builds.succeeded
        builds.failed = defaults.object(forKey: Keys.failed) as? Bool ?? builds.failed
        builds.canceled = defaults.object(forKey: Keys.canceled) as? Bool ?? builds.canceled
        builds.stuck = defaults.object(forKey: Keys.stuck) as? Bool ?? builds.stuck
        let factor = defaults.integer(forKey: Keys.stuckFactor)
        builds.stuckFactor = BuildNotificationRules.stuckFactors.contains(factor) ? factor : BuildNotificationRules.defaultStuckFactor
        builds.mutedProductIDs = Set(defaults.stringArray(forKey: Keys.mutedProductIDs) ?? [])
        self.builds = builds
        var usage = UsageAlertRules()
        usage.threshold75 = defaults.object(forKey: Keys.threshold75) as? Bool ?? usage.threshold75
        usage.threshold90 = defaults.object(forKey: Keys.threshold90) as? Bool ?? usage.threshold90
        usage.pace = defaults.object(forKey: Keys.pace) as? Bool ?? usage.pace
        self.usage = usage
    }

    func isMuted(_ productID: String) -> Bool {
        builds.mutedProductIDs.contains(productID)
    }

    func setMuted(_ muted: Bool, productID: String) {
        if muted {
            builds.mutedProductIDs.insert(productID)
        } else {
            builds.mutedProductIDs.remove(productID)
        }
    }

    private enum Keys {
        static let succeeded = "notifications.builds.succeeded"
        static let failed = "notifications.builds.failed"
        static let canceled = "notifications.builds.canceled"
        static let stuck = "notifications.builds.stuck"
        static let stuckFactor = "notifications.builds.stuckFactor"
        static let mutedProductIDs = "notifications.builds.mutedProductIDs"
        static let threshold75 = "notifications.usage.threshold75"
        static let threshold90 = "notifications.usage.threshold90"
        static let pace = "notifications.usage.pace"
    }
}
