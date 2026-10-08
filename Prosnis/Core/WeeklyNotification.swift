import Foundation
import UserNotifications

/// Воскресное напоминание посмотреть итоги недели.
@MainActor
enum WeeklyNotification {
    nonisolated static let identifier = "weekly-summary"

    static func update(enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Итоги недели готовы"
        content.body = "Сколько подъёмов, сколько выиграно времени и как выросло дерево — загляните."
        content.sound = .default
        var parts = DateComponents()
        parts.weekday = 1 // воскресенье
        parts.hour = 20
        parts.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

/// Нажатия на уведомления: итоги недели открывают свой экран.
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    @Published var showWeekly = false

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == WeeklyNotification.identifier {
            DispatchQueue.main.async { self.showWeekly = true }
        }
        completionHandler()
    }

    /// Уведомления видны и когда приложение открыто (например, «Время вышло»).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
