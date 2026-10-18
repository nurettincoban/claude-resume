import AppKit
import UserNotifications

/// "Claude finished" notifications. Clicking one opens that session's terminal tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with a session id when a notification is clicked.
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ session: Session, duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.subtitle = "\(session.folderName) · finished after \(Fmt.duration(duration))"
        content.body = session.lastReply.map { String($0.prefix(220)) } ?? "Waiting for your next message."
        content.sound = .default
        content.threadIdentifier = session.id
        content.userInfo = ["sessionId": session.id]
        // One notification per session: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: "finished-\(session.id)", content: content, trigger: nil)
        center.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            DispatchQueue.main.async { self.onOpen?(id) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
