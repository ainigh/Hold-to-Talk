import Foundation
import UserNotifications

/// macOS notifications for the updater and the reader. A click on an "update ready" one asks
/// whether to install it; a click on one of the reader's opens the reader where it points.
/// Only an installed app posts them: `UNUserNotificationCenter` needs a bundle (not `swift run`).
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let updateCategory = "update"
    /// What a click on an update notification does (set once, at launch).
    private var onInstall: (@MainActor () -> Void)?
    /// What a click on a reader notification does, given where it points ("forYou", "ask"…).
    private var onOpen: (@MainActor (String) -> Void)?

    @MainActor
    func start(onInstall: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor (String) -> Void = { _ in }) {
        guard Updater.canUpdate else { return }
        self.onInstall = onInstall
        self.onOpen = onOpen
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, update: Bool = false, open: String? = nil) {
        guard Updater.canUpdate else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if update { content.categoryIdentifier = updateCategory }
        if let open { content.userInfo = ["open": open] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Shown even while the app is in front (a menu bar app nearly always is, once its menu is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.updateCategory,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onInstall?() } }
        } else if let open = response.notification.request.content.userInfo["open"] as? String {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onOpen?(open) } }
        }
        completionHandler()
    }
}
