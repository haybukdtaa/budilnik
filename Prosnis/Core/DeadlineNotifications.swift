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

    /// Идущая перестановка: следующая ждёт её окончания, чтобы две не перемешали уведомления.
    private static var chain: Task<Void, Never>?

    /// Переставляет уведомления для будильников со ставкой на 10 дней вперёд. Берёт будильники в момент выполнения.
    static func refresh() async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await perform(now: Date())
        }
        chain = task
        await task.value
    }

    /// Утро этого звонка уже идёт, ждёт в очереди или записано: предупреждать не о чем.
    private static func isSettled(_ alarm: AlarmItem, ring: Date) -> Bool {
        if let session = WakeCoordinator.shared.session {
            if session.alarmID == alarm.id, abs((session.originalRing ?? session.startDate).timeIntervalSince(ring)) < 60 { return true }
            if WakeRules.isQueued(alarmID: alarm.id, ring: ring, queue: session.queuedAlarmIDs, rings: session.queuedRings) { return true }
        }
        return JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring)
    }

    /// Будильник всё ещё со ставкой и включён (между ожиданиями его могли изменить).
    private static func stillStaked(_ alarmID: UUID) -> AlarmItem? {
        AlarmStore.shared.alarms.first { $0.id == alarmID && $0.isEnabled && AlarmStore.shared.isStakeActive($0) }
    }

    private static func perform(now: Date) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !$0.hasPrefix(recheckPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        center.removePendingNotificationRequests(withIdentifiers: [refreshReminderID])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let alarms = AlarmStore.shared.alarms
        let context = AppSettings.shared.scheduleContext

        // Будильники по Фаджру и календарю поставлены до конца промежутка: за 3 дня до него напоминаем открыть приложение.
        let dated = alarms.filter { $0.isEnabled && $0.hasTask && $0.needsDatedSchedule }.map(\.id)
        if let end = AlarmService.shared.earliestHorizonEnd(for: dated) {
            let fire = end.addingTimeInterval(-Double(AlarmService.datedHorizonDays - refreshReminderDays) * 86400)
            if fire > now {
                let reminder = UNMutableNotificationContent()
                reminder.title = "Откройте «Проснись»"
                reminder.body = "Через 3 дня будильники по Фаджру и по праздникам перестанут ставиться. Утро без звонка из-за этого — провал."
                reminder.sound = .default
                try? await center.add(UNNotificationRequest(identifier: refreshReminderID, content: reminder, trigger: trigger(at: fire)))
            }
        }

        var planned: [(fire: Date, alarmID: UUID, ring: Date, amount: Int)] = []
        let horizon = now.addingTimeInterval(Double(AlarmService.datedHorizonDays + 1) * 86400)
        for alarm in alarms where alarm.isEnabled && AlarmStore.shared.isStakeActive(alarm) {
            for ring in ScheduleCalculator.effectiveOccurrences(for: alarm, from: now.addingTimeInterval(-WakeRules.windowSeconds), to: horizon, context: context) {
                let fire = ring.addingTimeInterval(WakeRules.windowSeconds)
                guard fire > now, !isSettled(alarm, ring: ring) else { continue }
                planned.append((fire, alarm.id, ring, alarm.stakeAmount))
            }
        }
        for item in planned.sorted(by: { $0.fire < $1.fire }).prefix(maxPending) {
            // Пока ставились предыдущие, утро могло начаться или будильник измениться: проверяем заново.
            guard let alarm = stillStaked(item.alarmID), !isSettled(alarm, ring: item.ring) else { continue }
            let identifier = id(alarmID: item.alarmID, ring: item.ring)
            try? await center.add(UNNotificationRequest(
                identifier: identifier,
                content: content(amount: item.amount, isRecheck: false),
                trigger: trigger(at: item.fire)
            ))
            if stillStaked(item.alarmID).map({ isSettled($0, ring: item.ring) }) ?? true {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            }
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
