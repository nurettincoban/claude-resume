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
        let receipt = session.lastTurn.map(Fmt.turn) ?? ""
        content.subtitle = "\(session.folderName) · " + (receipt.isEmpty ? "finished after \(Fmt.duration(duration))" : receipt)
        content.body = session.lastReply.map { String($0.prefix(220)) } ?? "Waiting for your next message."
        content.sound = .default
        content.threadIdentifier = session.key
        content.userInfo = ["sessionId": session.key]
        // One notification per session: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: "finished-\(session.key)", content: content, trigger: nil)
        center.add(request)
    }

    /// Claude is blocked on a permission prompt or a question.
    func postNeedsInput(_ session: Session, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.subtitle = "\(session.folderName) · \(reason)"
        content.body = "Claude is waiting for you to answer before it can continue."
        content.sound = .default
        content.threadIdentifier = session.key
        content.userInfo = ["sessionId": session.key]
        center.add(UNNotificationRequest(identifier: "waiting-\(session.key)", content: content, trigger: nil))
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
