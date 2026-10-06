import Foundation
import SwiftUI

/// Утро после успешного подъёма: чек-лист, программа модуля, рост дерева и опыта.
struct MorningState: Identifiable, Equatable {
    let id = UUID()
    let entryID: UUID
    let module: WakeModule
    let xpBefore: Int
    let levelBefore: Int
    let badgesBefore: Set<String>
    let treeStageBefore: Int
    let startedAt: Date
}

/// Ведёт утро от звонка до итога: задание, повторная проверка, деньги, запись в журнал.
@MainActor
final class WakeCoordinator: ObservableObject {
    static let shared = WakeCoordinator()

    @Published private(set) var session: WakeSession?
    @Published var morning: MorningState?

    private let service = AlarmService.shared
    private let file = FileStore<WakeSession>("wake_session")
    private static let lastReconcileKey = "lastReconcile"

    private init() {
        session = file.load()
    }

    func reload() {
        session = file.load()
        morning = nil
    }

    private func setSession(_ value: WakeSession?) {
        session = value
        if let value {
            file.save(value)
        } else {
            file.delete()
        }
    }

    private var context: ScheduleContext { AppSettings.shared.scheduleContext }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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
              alarm.hasTask else { return }

        let ring = AlarmStore.shared.lastOccurrence(of: alarm, onOrBefore: now) ?? now
        begin(alarm: alarm, ring: ring, now: now, note: "Нажато «Выключить»")
    }

    private func begin(alarm: AlarmItem, ring: Date, now: Date, note: String) {
        var kind = alarm.effectiveTask
        if kind == .qr && (alarm.qrCode ?? "").isEmpty { kind = .typing }
        let stake = alarm.stakeEnabled ? alarm.stakeAmount : 0
        let reference: UUID? = stake > 0 ? UUID() : nil

        setSession(WakeSession(
            alarmID: alarm.id,
            alarmTitle: alarm.displayTitle,
            timeText: WakeCoordinator.clock(ring),
            stake: stake,
            wallpaper: alarm.wallpaper,
            soundID: alarm.soundID,
            startDate: ring,
            stage: 1,
            phase: .task,
            ringDate: ring,
            sentence: SentenceBank.random(),
            events: [
                JournalEvent(date: ring, text: "Прозвенел будильник"),
                JournalEvent(date: now, text: note),
            ],
            taskKind: kind,
            qrCode: alarm.qrCode,
            module: alarm.effectiveModule,
            isPrayer: alarm.isPrayerRelated,
            paymentRef: reference
        ))
        if let reference {
            Task { await PaymentsStore.shared.hold(amount: stake, reference: reference) }
        }
        evaluate(now)
    }

    /// Запасной вход: если «Выключить» не открыло приложение, задание начинается,
    /// когда его открыли вручную в течение 10 минут после звонка.
    private func lateStart(_ now: Date) {
        guard session == nil else { return }
        for alarm in AlarmStore.shared.alarms where alarm.hasTask && alarm.isEnabled {
            guard let ring = AlarmStore.shared.lastOccurrence(of: alarm, onOrBefore: now),
                  now.timeIntervalSince(ring) < WakeRules.windowSeconds,
                  ring > (alarm.createdAt ?? .distantPast),
                  !JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) else { continue }
            if let once = ScheduleCalculator.onceDate(for: alarm, context: context),
               abs(once.timeIntervalSince(ring)) >= 60 { continue }

            begin(alarm: alarm, ring: ring, now: now, note: "Приложение открыто вручную после звонка")
            return
        }
    }

    /// Быстрая проверка всего сценария: повторная проверка через минуту, а не через 10.
    func startDemo(task: TaskKind = .typing) {
        guard session == nil else { return }
        let now = Date()
        setSession(WakeSession(
            alarmID: UUID(),
            alarmTitle: "Проверка",
            timeText: WakeCoordinator.clock(now),
            stake: 0,
            wallpaper: .gradient(0),
            soundID: "classic_beep",
            startDate: now,
            stage: 1,
            phase: .task,
            ringDate: now,
            recheckDelay: 60,
            sentence: SentenceBank.random(),
            events: [JournalEvent(date: now, text: "Запущена проверка сценария")],
            isDemo: true,
            taskKind: task == .qr ? .typing : task,
            module: .basic
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

    /// Задание выполнено.
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
            guard var latest = session, latest.alarmID == snapshot.alarmID, latest.startDate == snapshot.startDate else {
                if let id { service.cancel(id: id) }
                return
            }
            if let id {
                latest.recheckAlarmID = id
                latest.events.append(JournalEvent(date: Date(), text: "Повторная проверка назначена на \(WakeCoordinator.clock(recheckAt))"))
                setSession(latest)
            } else {
                // Не удалось назначить повторный звонок: это наш сбой, этап засчитываем.
                latest.events.append(JournalEvent(date: Date(), text: "Повторный звонок назначить не удалось, этап засчитан"))
                finish(latest, outcome: .success)
            }
        }
    }

    /// Задание не может быть выполнено (например, нет камеры): переключаемся на печать, срок прежний.
    func switchToTyping(reason: String) {
        guard var current = session, current.phase == .task, current.taskKind != .typing else { return }
        current.taskKind = .typing
        current.events.append(JournalEvent(date: Date(), text: reason))
        setSession(current)
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
        let before = ProgressEngine.compute(entries: JournalStore.shared.realEntries, challenges: ChallengeStore.shared.challenges)

        let entry = JournalEntry(
            date: finished.startDate,
            alarmID: finished.isDemo ? nil : finished.alarmID,
            alarmTitle: finished.alarmTitle,
            timeText: finished.timeText,
            stake: finished.stake,
            outcome: outcome,
            events: finished.events,
            isTraining: PaymentsStore.shared.isTraining,
            isDemo: finished.isDemo ? true : nil,
            module: finished.module,
            isPrayer: finished.isPrayer ? true : nil,
            taskKind: finished.taskKind,
            paymentRef: finished.paymentRef
        )
        setSession(nil)
        JournalStore.shared.add(entry)

        if let reference = finished.paymentRef {
            Task { await PaymentsStore.shared.settle(reference: reference, success: outcome == .success) }
        }

        if outcome == .success {
            morning = MorningState(
                entryID: entry.id,
                module: finished.module,
                xpBefore: before.xp,
                levelBefore: before.level,
                badgesBefore: Set(before.unlocked.map(\.id)),
                treeStageBefore: before.tree.stage,
                startedAt: Date()
            )
        }
    }

    // MARK: - Сверка пропущенных звонков

    /// Находит утра, когда приложение так и не открыли, и записывает их в журнал.
    func reconcile(now: Date = Date()) {
        evaluate(now)
        lateStart(now)

        let defaults = UserDefaults.standard
        let lastCheck = (defaults.object(forKey: WakeCoordinator.lastReconcileKey) as? Date) ?? now
        defer { defaults.set(now, forKey: WakeCoordinator.lastReconcileKey) }

        let window = WakeRules.windowSeconds
        let context = self.context

        for alarm in AlarmStore.shared.alarms where alarm.stakeEnabled && alarm.isEnabled {
            let from = max(lastCheck, alarm.createdAt ?? lastCheck)
            let to = now.addingTimeInterval(-2 * window)
            for ring in ScheduleCalculator.effectiveOccurrences(for: alarm, from: from, to: to, context: context) {
                if let active = session, active.alarmID == alarm.id,
                   abs(active.startDate.timeIntervalSince(ring)) < 3600 { continue }
                if JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) { continue }
                recordMissed(alarm: alarm, ring: ring)
            }
        }

        // Одноразовые будильники выключаются после срабатывания.
        for alarm in AlarmStore.shared.alarms where alarm.isEnabled {
            if let once = ScheduleCalculator.onceDate(for: alarm, context: context),
               once.addingTimeInterval(60) <= now,
               session?.alarmID != alarm.id {
                AlarmStore.shared.disableSilently(alarm.id)
            }
        }
    }

    private func recordMissed(alarm: AlarmItem, ring: Date) {
        let forgive = Bedtime.wasChecked(before: ring) && !JournalStore.shared.hasForgiven(before: ring)
        let window = WakeRules.windowSeconds
        var events = [JournalEvent(date: ring, text: "Прозвенел будильник")]
        events.append(JournalEvent(
            date: ring.addingTimeInterval(window),
            text: forgive
                ? "Приложение не открывали. Вечерняя проверка была пройдена, первый такой случай прощён"
                : "Приложение не открывали, задание не выполнено"
        ))

        let reference: UUID? = (!forgive && alarm.stakeAmount > 0) ? UUID() : nil
        JournalStore.shared.add(JournalEntry(
            date: ring,
            alarmID: alarm.id,
            forgiven: forgive ? true : nil,
            alarmTitle: alarm.displayTitle,
            timeText: WakeCoordinator.clock(ring),
            stake: alarm.stakeAmount,
            outcome: forgive ? .technical : .failed,
            events: events,
            isTraining: PaymentsStore.shared.isTraining,
            module: alarm.effectiveModule,
            isPrayer: alarm.isPrayerRelated ? true : nil,
            taskKind: alarm.effectiveTask,
            paymentRef: reference
        ))
        if let reference {
            let amount = alarm.stakeAmount
            Task {
                if await PaymentsStore.shared.hold(amount: amount, reference: reference) {
                    await PaymentsStore.shared.settle(reference: reference, success: false)
                }
            }
        }
    }

    func finishMorning() {
        morning = nil
    }
}
