import Foundation
import SwiftUI

/// Ведёт утро от звонка до итога: задание, повторная проверка, запись в журнал.
@MainActor
final class WakeCoordinator: ObservableObject {
    static let shared = WakeCoordinator()

    @Published private(set) var session: WakeSession?

    private let service = AlarmService()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("wake_session.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(WakeSession.self, from: data) {
            session = saved
        }
    }

    private func persist() {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func setSession(_ value: WakeSession?) {
        session = value
        persist()
    }

    // MARK: - Вход: нажали «Выключить»

    /// Вызывается из интента, когда на звонке нажали «Выключить».
    func handleStop(alarmID: UUID?, isRecheck: Bool) {
        guard let alarmID else { return }
        let now = Date()

        if isRecheck {
            guard var current = session, current.alarmID == alarmID, current.phase == .waiting else { return }
            current.stage = 2
            current.phase = .task
            current.ringDate = current.recheckDate ?? now
            current.sentence = SentenceBank.random(excluding: current.sentence)
            current.events.append(JournalEvent(date: current.ringDate, text: "Прозвенела повторная проверка"))
            current.events.append(JournalEvent(date: now, text: "Нажато «Выключить»"))
            setSession(current)
            evaluate(now)
            return
        }

        if let current = session, current.alarmID == alarmID { return }
        guard session == nil,
              let alarm = AlarmStore.shared.alarms.first(where: { $0.id == alarmID }),
              alarm.stakeEnabled else { return }

        let ring = alarm.lastOccurrence(onOrBefore: now) ?? now
        setSession(WakeSession(
            alarmID: alarm.id,
            alarmTitle: alarm.displayTitle,
            timeText: alarm.timeText,
            stake: alarm.stakeAmount,
            wallpaper: alarm.wallpaper,
            soundID: alarm.soundID,
            startDate: ring,
            stage: 1,
            phase: .task,
            ringDate: ring,
            sentence: SentenceBank.random(),
            events: [
                JournalEvent(date: ring, text: "Прозвенел будильник"),
                JournalEvent(date: now, text: "Нажато «Выключить»"),
            ]
        ))
        evaluate(now)
    }

    /// Быстрая проверка всего сценария: повторная проверка через минуту, а не через 10.
    func startDemo() {
        guard session == nil else { return }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        setSession(WakeSession(
            alarmID: UUID(),
            alarmTitle: "Проверка",
            timeText: formatter.string(from: now),
            stake: 500,
            wallpaper: .gradient(0),
            soundID: "classic_beep",
            startDate: now,
            stage: 1,
            phase: .task,
            ringDate: now,
            recheckDelay: 60,
            sentence: SentenceBank.random(),
            events: [
                JournalEvent(date: now, text: "Запущена проверка сценария"),
            ],
            isDemo: true
        ))
    }

    // MARK: - Ход задания

    /// Проверяет сроки. Вызывается раз в секунду, пока открыт экран.
    func evaluate(_ now: Date = Date()) {
        guard let current = session else { return }
        switch current.phase {
        case .task:
            if now >= current.deadline {
                fail(
                    current.stage == 1 ? "Время на задание истекло" : "Время на повторное задание истекло",
                    at: current.deadline
                )
            }
        case .waiting:
            if let recheck = current.recheckDate,
               now >= recheck.addingTimeInterval(WakeRules.windowSeconds) {
                fail("На повторную проверку не ответили", at: recheck.addingTimeInterval(WakeRules.windowSeconds))
            }
        }
    }

    /// Предложение напечатано верно.
    func submit(_ now: Date = Date()) {
        guard var current = session, current.phase == .task else { return }
        if now > current.deadline {
            evaluate(now)
            return
        }

        if current.stage == 2 {
            current.events.append(JournalEvent(date: now, text: "Повторное задание выполнено"))
            finish(current, outcome: .success)
            return
        }

        let recheckAt = now.addingTimeInterval(current.recheckDelay)
        current.events.append(JournalEvent(date: now, text: "Задание выполнено"))
        current.phase = .waiting
        current.recheckDate = recheckAt
        setSession(current)

        let snapshot = current
        Task {
            let id = await service.scheduleRecheck(alarmID: snapshot.alarmID, soundID: snapshot.soundID, at: recheckAt)
            guard var latest = session, latest.alarmID == snapshot.alarmID else { return }
            if let id {
                latest.recheckAlarmID = id
                latest.events.append(JournalEvent(date: Date(), text: "Повторная проверка назначена"))
                setSession(latest)
            } else {
                // Не удалось назначить повторный звонок: это наш сбой, этап засчитываем.
                latest.events.append(JournalEvent(date: Date(), text: "Повторный звонок назначить не удалось, этап засчитан"))
                finish(latest, outcome: .success)
            }
        }
    }

    private func fail(_ reason: String, at date: Date) {
        guard var current = session else { return }
        current.events.append(JournalEvent(date: date, text: reason))
        finish(current, outcome: .failed)
    }

    private func finish(_ finished: WakeSession, outcome: Outcome) {
        if let recheckID = finished.recheckAlarmID {
            service.cancel(id: recheckID)
        }
        JournalStore.shared.add(JournalEntry(
            date: finished.startDate,
            alarmID: finished.isDemo ? nil : finished.alarmID,
            alarmTitle: finished.alarmTitle,
            timeText: finished.timeText,
            stake: finished.stake,
            outcome: outcome,
            events: finished.events
        ))
        setSession(nil)
    }

    // MARK: - Сверка пропущенных звонков

    /// Находит утра, когда приложение так и не открыли, и записывает их в журнал.
    func reconcile(now: Date = Date()) {
        evaluate(now)

        let defaults = UserDefaults.standard
        let lastCheck = (defaults.object(forKey: "lastReconcile") as? Date) ?? now
        defer { defaults.set(now, forKey: "lastReconcile") }

        let calendar = Calendar.current
        let window = WakeRules.windowSeconds

        for alarm in AlarmStore.shared.alarms where alarm.stakeEnabled && alarm.isEnabled {
            let from = max(lastCheck, alarm.createdAt ?? lastCheck)
            // Первое срабатывание одноразового будильника после создания.
            let onceDate = alarm.weekdays.isEmpty
                ? calendar.nextDate(
                    after: alarm.createdAt ?? from,
                    matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
                    matchingPolicy: .nextTime
                )
                : nil

            for offset in -14...0 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let ring = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: day),
                      ring > from,
                      ring.addingTimeInterval(2 * window) <= now else { continue }

                if alarm.weekdays.isEmpty {
                    guard let onceDate, abs(onceDate.timeIntervalSince(ring)) < 60 else { continue }
                } else if !alarm.matchesWeekday(ring) {
                    continue
                }

                if let active = session, active.alarmID == alarm.id,
                   abs(active.startDate.timeIntervalSince(ring)) < 3600 { continue }
                if JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) { continue }

                recordMissed(alarm: alarm, ring: ring)
            }

            if let onceDate, onceDate.addingTimeInterval(60) <= now {
                AlarmStore.shared.disableSilently(alarm.id)
            }
        }
    }

    private func recordMissed(alarm: AlarmItem, ring: Date) {
        let forgive = Bedtime.wasChecked(before: ring) && !JournalStore.shared.hasForgiven(before: ring)
        let window = WakeRules.windowSeconds
        var events = [JournalEvent(date: ring, text: "Прозвенел будильник")]
        if forgive {
            events.append(JournalEvent(
                date: ring.addingTimeInterval(window),
                text: "Приложение не открывали. Вечерняя проверка была пройдена, первый такой случай прощён"
            ))
        } else {
            events.append(JournalEvent(
                date: ring.addingTimeInterval(window),
                text: "Приложение не открывали, задание не выполнено"
            ))
        }
        JournalStore.shared.add(JournalEntry(
            date: ring,
            alarmID: alarm.id,
            forgiven: forgive ? true : nil,
            alarmTitle: alarm.displayTitle,
            timeText: alarm.timeText,
            stake: alarm.stakeAmount,
            outcome: forgive ? .technical : .failed,
            events: events
        ))
    }
}
