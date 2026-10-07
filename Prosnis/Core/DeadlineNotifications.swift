import Foundation
import UserNotifications

/// Уведомление «время вышло» через 10 минут после звонка будильника со ставкой.
/// Ставится заранее: iOS покажет его сама, даже если приложение закрыто. Снимается, когда задание начато.
@MainActor
enum DeadlineNotifications {
    /// iOS хранит не больше 64 запланированных уведомлений; оставляем запас.
    static let maxPending = 50
    private static let prefix = "deadline-"
    private static let recheckPrefix = "deadline-recheck-"
    private static let refreshReminderID = "refresh-reminder"
    /// Через сколько дней без открытия напомнить, что будильники по Фаджру и календарю скоро закончатся.
    static let refreshReminderDays = 7

    static func id(alarmID: UUID, ring: Date) -> String {
        "\(prefix)\(alarmID.uuidString)-\(Int(ring.timeIntervalSince1970))"
    }

    static func recheckID(alarmID: UUID, recheck: Date) -> String {
        "\(recheckPrefix)\(alarmID.uuidString)-\(Int(recheck.timeIntervalSince1970))"
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func content(amount: Int, isRecheck: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Время вышло"
        let what = isRecheck ? "Вторая проверка не пройдена" : "Задание не выполнено за 10 минут"
        let training = PaymentsStore.shared.isTraining ? " (тренировка: деньги не двигаются)" : ""
        content.body = "\(what). Ставка \(amount) ₽ будет списана\(training)."
        content.sound = .default
        return content
    }

    private static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
    }

    /// Переставляет уведомления для будильников со ставкой на 10 дней вперёд.
    static func refresh(alarms: [AlarmItem], context: ScheduleContext, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !$0.hasPrefix(recheckPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        center.removePendingNotificationRequests(withIdentifiers: [refreshReminderID])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        // Будильники по Фаджру и календарю ставятся на 10 дней вперёд: на 7-й день без открытия напоминаем.
        if alarms.contains(where: { $0.isEnabled && $0.hasTask && $0.needsDatedSchedule }) {
            let reminder = UNMutableNotificationContent()
            reminder.title = "Откройте «Проснись»"
            reminder.body = "Через 3 дня будильники по Фаджру и по праздникам перестанут ставиться. Утро без звонка из-за этого — провал."
            reminder.sound = .default
            let fire = now.addingTimeInterval(Double(refreshReminderDays) * 86400)
            try? await center.add(UNNotificationRequest(identifier: refreshReminderID, content: reminder, trigger: trigger(at: fire)))
        }

        var planned: [(Date, UNNotificationRequest)] = []
        let horizon = now.addingTimeInterval(Double(AlarmService.datedHorizonDays) * 86400)
        for alarm in alarms where alarm.stakeEnabled && alarm.isEnabled && alarm.stakeAmount > 0 {
            for ring in ScheduleCalculator.effectiveOccurrences(for: alarm, from: now.addingTimeInterval(-WakeRules.windowSeconds), to: horizon, context: context) {
                let fire = ring.addingTimeInterval(WakeRules.windowSeconds)
                guard fire > now else { continue }
                // Утро уже начато или записано: предупреждать не о чем.
                if WakeCoordinator.shared.session?.alarmID == alarm.id { continue }
                if JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) { continue }
                let request = UNNotificationRequest(
                    identifier: id(alarmID: alarm.id, ring: ring),
                    content: content(amount: alarm.stakeAmount, isRecheck: false),
                    trigger: trigger(at: fire)
                )
                planned.append((fire, request))
            }
        }
        for (_, request) in planned.sorted(by: { $0.0 < $1.0 }).prefix(maxPending) {
            try? await center.add(request)
        }
    }

    /// Задание начато: предупреждение для этого звонка больше не нужно.
    static func cancel(alarmID: UUID, ring: Date) {
        let identifier = id(alarmID: alarmID, ring: ring)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func scheduleRecheckDeadline(alarmID: UUID, recheck: Date, amount: Int) async {
        guard amount > 0 else { return }
        let request = UNNotificationRequest(
            identifier: recheckID(alarmID: alarmID, recheck: recheck),
            content: content(amount: amount, isRecheck: true),
            trigger: trigger(at: recheck.addingTimeInterval(WakeRules.windowSeconds))
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancelRecheck(alarmID: UUID, recheck: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [recheckID(alarmID: alarmID, recheck: recheck)]
        )
    }
}
