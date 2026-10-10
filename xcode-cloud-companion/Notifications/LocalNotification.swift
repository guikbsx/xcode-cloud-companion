import Foundation
import UserNotifications

/// One banner of Notification Center. `id` replaces an earlier banner of the same subject; a click opens `url`.
nonisolated struct LocalNotification: Sendable, Equatable {
    var id: String
    var title: String
    var body: String
    /// A `cumulus://` address, the only kind a click ever follows.
    var url: URL?
    /// Banners of one app stack together.
    var thread: String?
}

nonisolated enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
}

/// What the app needs from Notification Center; tests stand in for it.
nonisolated protocol NotificationPosting: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
    func post(_ notification: LocalNotification) async
}

/// Local notifications only: nothing is pushed, every banner comes from what the sync just read.
nonisolated struct SystemNotificationCenter: NotificationPosting {
    static let urlKey = "url"

    @concurrent func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    @concurrent func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    @concurrent func post(_ notification: LocalNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let thread = notification.thread {
            content.threadIdentifier = thread
        }
        if let url = notification.url {
            content.userInfo = [Self.urlKey: url.absoluteString]
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }
}

/// Receives the click on a banner. Notification Center calls it off the main thread: it is isolated to nothing,
/// and hands the address over to the main actor.
nonisolated final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (URL) -> Void

    init(open: @escaping @MainActor @Sendable (URL) -> Void) {
        self.open = open
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let address = response.notification.request.content.userInfo[SystemNotificationCenter.urlKey] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let url = address.flatMap(URL.init(string:)) {
            let open = open
            Task { @MainActor in open(url) }
        }
        completionHandler()
    }

    /// A build that ends while the window is in front is still worth a banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
