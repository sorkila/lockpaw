import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "AgentNotifier")

/// Posts a local macOS notification when an AI agent pings Lockpaw.
/// Notification permission is requested lazily on first use, so onboarding stays
/// unchanged — if the user declines, the lock-screen glow still fires silently.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        // Without a delegate that opts in, macOS suppresses banners while Lockpaw is
        // frontmost (e.g. the Settings test button, or while the lock overlay is up).
        center.delegate = self
    }

    /// Present banners (and sound) even when Lockpaw is the foreground app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Fire a "your agent needs you" notification. Sound is attached only when the
    /// user has opted in (off by default for shared/open-plan spaces).
    func notify(withSound: Bool) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.post(withSound: withSound)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { logger.error("Notification auth error: \(error.localizedDescription)") }
                    if granted { self.post(withSound: withSound) }
                }
            default:
                logger.info("Notifications not authorized — relying on lock-screen glow only")
            }
        }
    }

    /// Remove our delivered banners from Notification Center. Called on unlock —
    /// "your agent needs you" is stale once the user is back at the machine.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    private func post(withSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Lockpaw"
        content.body = "Your agent needs you."
        content.sound = withSound ? .default : nil

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { logger.error("Failed to post notification: \(error.localizedDescription)") }
        }
    }
}
