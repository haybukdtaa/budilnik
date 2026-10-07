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
    let treeIndexBefore: Int
    let flowersBefore: Bool
    let fruitsBefore: Bool
    let startedAt: Date
}

/// Ведёт утро от звонка до итога: задание, повторная проверка, деньги, запись в журнал.
@MainActor
final class WakeCoordinator: ObservableObject {
    static let shared = WakeCoordinator()

    @Published private(set) var session: WakeSession?
    @Published var morning: MorningState?
    /// Утренние экраны, которые покажутся по очереди, когда закроется экран задания.
    private var pendingMornings: [MorningState] = []

    private let service = AlarmService.shared
    private let file = FileStore<WakeSession>("wake_session")
    private var loadFailed = false
    /// Повторный звонок сейчас ставится: второй раз не ставим.
    private var isArmingRecheck = false
    private static let lastReconcileKey = "lastReconcile"

    private init() {
        let result = file.loadWithState()
        session = result.value
        loadFailed = result.state == .unreadable
    }

    func reload() {
        let result = file.loadWithState()
        session = result.value
        loadFailed = result.state == .unreadable
        morning = nil
        pendingMornings = []
    }

    func reloadIfNeeded() {
        guard loadFailed, session == nil else { return }
        reload()
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

    private func isQueued(_ alarmID: UUID) -> Bool {
        session?.queuedAlarmIDs?.contains(alarmID) == true
    }

    /// Ждёт ли в очереди именно этот звонок.
    private func isQueued(_ alarmID: UUID, ring: Date) -> Bool {
        WakeRules.isQueued(alarmID: alarmID, ring: ring, queue: session?.queuedAlarmIDs, rings: session?.queuedRings)
    }

    /// Идёт ли задание именно этого звонка.
    private func isActiveRing(_ alarmID: UUID, _ ring: Date) -> Bool {
        guard let active = session, active.alarmID == alarmID else { return false }
        return abs((active.originalRing ?? active.startDate).timeIntervalSince(ring)) < 60
    }

    /// Звонок, который только что был: по расписанию в текущем поясе или ожидавшийся при постановке
    /// (системный будильник на конкретную дату не сдвигается при смене пояса).
    private func recentRing(of alarm: AlarmItem, now: Date) -> Date? {
        let scheduled = AlarmStore.shared.lastOccurrence(of: alarm, onOrBefore: now)
        let expected = service.expectedRings(for: alarm).map(\.at).filter { $0 <= now }.max()
        return [scheduled, expected].compactMap { $0 }.max()
    }

    /// Все возможные времена звонков будильника около промежутка: по текущему поясу и ожидавшиеся при постановке.
    private func ringCandidates(_ alarm: AlarmItem, from: Date, to: Date) -> [RingCandidate] {
        let changed = AlarmStore.changedAt(alarm)
        let recomputed = ScheduleCalculator.effectiveOccurrences(
            for: alarm, from: from.addingTimeInterval(-2 * 86400), to: to.addingTimeInterval(2 * 86400), context: context
        ).filter { $0 > changed }
        let stored = service.expectedRings(for: alarm).filter { $0.at > changed }
        return MissedMornings.merged(stored, MissedMornings.candidates(recomputed, calendar: context.calendar))
    }

    /// Закрыто ли это время звонка: записано, идёт или ждёт в очереди.
    private func isCovered(_ alarm: AlarmItem, _ ring: Date) -> Bool {
        isActiveRing(alarm.id, ring) || isQueued(alarm.id, ring: ring)
            || JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring)
    }

    /// Есть ли у будильника утро, которое ещё не решено (например, после смены пояса ждёт второго времени звонка).
    func hasUnresolvedMorning(_ alarm: AlarmItem, now: Date) -> Bool {
        guard alarm.hasTask, alarm.isEnabled else { return false }
        let candidates = ringCandidates(alarm, from: now.addingTimeInterval(-36 * 3600), to: now)
        return MissedMornings.hasUnresolved(candidates: candidates, now: now) { isCovered(alarm, $0) }
    }

    // MARK: - Вход: нажали «Выключить»

    /// Вызывается из интента, когда на звонке нажали «Выключить».
    func handleStop(alarmID: UUID?, isRecheck: Bool) {
        guard let alarmID else { return }
        let now = TrustedClock.now

        if isRecheck {
            guard let current = session, current.alarmID == alarmID, current.phase == .waiting else { return }
            startStageTwo(current, now: now, note: "Нажато «Выключить»")
            return
        }

        guard let alarm = AlarmStore.shared.alarms.first(where: { $0.id == alarmID }),
              alarm.hasTask, alarm.isEnabled else { return }
        let ring = recentRing(of: alarm, now: now) ?? now
        // Это утро уже записано (например, звонок от устаревшего системного будильника).
        guard !JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) else { return }

        if var current = session {
            guard current.alarmID != alarm.id else { return }
            // Идёт проверка другого будильника: этот начнётся сразу после неё.
            var queue = current.queuedAlarmIDs ?? []
            if !queue.contains(alarm.id) {
                queue.append(alarm.id)
                current.queuedAlarmIDs = queue
                current.queuedRings = (current.queuedRings ?? [:]).merging([alarm.id.uuidString: ring]) { _, new in new }
                current.events.append(JournalEvent(date: now, text: "Во время проверки прозвенел будильник «\(alarm.displayTitle)», его задание начнётся следом"))
                setSession(current)
                // Человек занят другой проверкой: «время вышло» по этому звонку было бы неправдой.
                DeadlineNotifications.cancel(alarmID: alarm.id, ring: ring)
            }
            return
        }

        begin(alarm: alarm, ring: ring, now: now, note: "Нажато «Выключить»")
    }

    /// Переводит сессию на вторую проверку.
    private func startStageTwo(_ value: WakeSession, now: Date, note: String) {
        var current = value
        current.stage = 2
        current.phase = .task
        current.ringDate = current.recheckDate ?? now
        current.sentence = SentenceBank.random(excluding: current.sentence)
        current.events.append(JournalEvent(date: current.ringDate, text: "Прозвенела повторная проверка"))
        current.events.append(JournalEvent(date: now, text: note))
        setSession(current)
        evaluate(now)
    }

    private func begin(
        alarm: AlarmItem, ring: Date, now: Date, note: String,
        queue: [UUID]? = nil, queuedRings: [String: Date]? = nil, originalRing: Date? = nil
    ) {
        var kind = alarm.effectiveTask
        if kind == .qr && (alarm.qrCode ?? "").isEmpty { kind = .typing }
        // Ставка действует только при согласии с текущими условиями.
        let stake = AlarmStore.shared.isStakeActive(alarm) ? alarm.stakeAmount : 0
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
            paymentRef: reference,
            queuedAlarmIDs: queue,
            queuedRings: queuedRings,
            originalRing: originalRing
        ))
        if let reference {
            Task { await PaymentsStore.shared.hold(amount: stake, reference: reference) }
        }
        let morningRing = originalRing ?? ring
        DeadlineNotifications.cancel(alarmID: alarm.id, ring: morningRing)
        if let started = session { emit(.started, session: started, at: now) }
        evaluate(now)
    }

    /// Событие утра для сервера: подписано, уходит через очередь. Тест и утра с намазом без согласия не уходят.
    private func emit(_ kind: WakeEventKind, session value: WakeSession, at date: Date) {
        guard !value.isDemo else { return }
        if value.isPrayer && !AppSettings.shared.data.privacy.syncPrayerData { return }
        let ring = value.originalRing ?? value.startDate
        let morning = WakeEvent.morningID(alarmID: value.alarmID, ring: ring)
        let at = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let event = WakeEvent(
            morningID: morning, alarmID: value.alarmID, ring: ring, kind: kind, at: at,
            signature: AccountStore.shared.sign(WakeEvent.signedMessage(morningID: morning, kind: kind, at: at))
        )
        SyncEngine.shared.enqueue(.wakeEvent, id: event.id, value: event, sensitive: value.isPrayer)
        // Для сервера решает время получения: отправляем сразу, не дожидаясь следующего открытия.
        SyncEngine.shared.flushSoon()
    }

    /// Запасной вход: если «Выключить» не открыло приложение, задание начинается,
    /// когда его открыли вручную в течение 10 минут после звонка.
    private func lateStart(_ now: Date) {
        guard session == nil else { return }
        var ringing: [(AlarmItem, Date)] = []
        for alarm in AlarmStore.shared.alarms where alarm.hasTask && alarm.isEnabled {
            guard let ring = recentRing(of: alarm, now: now),
                  now.timeIntervalSince(ring) < WakeRules.windowSeconds,
                  // Звонок был после последнего изменения будильника (включение тоже изменение).
                  ring > AlarmStore.changedAt(alarm),
                  !JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) else { continue }
            if let once = ScheduleCalculator.onceDate(for: alarm, context: context),
               abs(once.timeIntervalSince(ring)) >= 60 { continue }
            ringing.append((alarm, ring))
        }
        ringing.sort { $0.1 < $1.1 }
        guard let (first, firstRing) = ringing.first else { return }
        // Остальные прозвеневшие будильники ждут в очереди, а не считаются проспанными.
        let rest = ringing.dropFirst()
        begin(
            alarm: first, ring: firstRing, now: now, note: "Приложение открыто вручную после звонка",
            queue: rest.isEmpty ? nil : rest.map(\.0.id),
            queuedRings: rest.isEmpty ? nil : Dictionary(uniqueKeysWithValues: rest.map { ($0.0.id.uuidString, $0.1) })
        )
    }

    /// Запускает задание будильника, который прозвенел во время предыдущей проверки.
    /// Время на задание отсчитывается с этого момента: человек был занят первой проверкой.
    private func startQueued(_ queue: [UUID], rings: [String: Date], now: Date) {
        var remaining = queue
        while !remaining.isEmpty {
            let id = remaining.removeFirst()
            guard let alarm = AlarmStore.shared.alarms.first(where: { $0.id == id }),
                  alarm.hasTask, alarm.isEnabled else { continue }
            let ring = rings[id.uuidString] ?? AlarmStore.shared.lastOccurrence(of: alarm, onOrBefore: now) ?? now
            if JournalStore.shared.hasEntry(alarmID: alarm.id, near: ring) { continue }
            // Давно прозвеневший будильник уже не запускаем: его звонок сверка запишет как пропуск.
            if WakeRules.isQueuedRingStale(ring, now: now) { continue }
            let restRings = rings.filter { key, _ in remaining.contains { $0.uuidString == key } }
            begin(
                alarm: alarm, ring: now, now: now,
                note: "Будильник прозвенел в \(WakeCoordinator.clock(ring)) во время другой проверки, задание начато после неё",
                queue: remaining.isEmpty ? nil : remaining,
                queuedRings: remaining.isEmpty ? nil : restRings,
                originalRing: ring
            )
            return
        }
    }

    /// Быстрая проверка всего сценария: повторная проверка через минуту, а не через 10.
    func startDemo(task: TaskKind = .typing) {
        guard session == nil else { return }
        let now = TrustedClock.now
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
    func evaluate(_ now: Date = TrustedClock.now) {
        guard let current = session else { return }
        // Повторный звонок мог не открыть приложение: если оно открыто, начинаем вторую проверку сами.
        if current.phase == .waiting, let recheck = current.recheckDate,
           WakeRules.shouldStartRecheckInApp(recheckDate: recheck, now: now) {
            if let recheckID = current.recheckAlarmID {
                service.stop(id: recheckID)
                service.cancel(id: recheckID)
            }
            var updated = current
            updated.recheckAlarmID = nil
            startStageTwo(updated, now: now, note: "Вторая проверка начата в приложении")
            return
        }
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
    func submit(_ now: Date = TrustedClock.now) {
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
        emit(.taskDone, session: current, at: now)
        if !current.isDemo {
            let alarmID = current.alarmID
            let amount = current.stake
            Task { await DeadlineNotifications.scheduleRecheckDeadline(alarmID: alarmID, recheck: recheckAt, amount: amount) }
        }

        armRecheck(current, at: recheckAt)
    }

    /// Ставит системный повторный звонок. Если поставить нельзя: выключенное разрешение — выбор человека (провал),
    /// иначе сбой системы (без списания, но и без успеха).
    private func armRecheck(_ snapshot: WakeSession, at recheckAt: Date) {
        guard !isArmingRecheck else { return }
        isArmingRecheck = true
        Task {
            defer { isArmingRecheck = false }
            let id = await service.scheduleRecheck(alarmID: snapshot.alarmID, soundID: snapshot.soundID, at: recheckAt)
            guard var latest = session, latest.alarmID == snapshot.alarmID, latest.startDate == snapshot.startDate,
                  latest.stage == 1, latest.phase == .waiting else {
                if let id { service.cancel(id: id) }
                return
            }
            if let id {
                latest.recheckAlarmID = id
                latest.events.append(JournalEvent(date: Date(), text: "Повторная проверка назначена на \(WakeCoordinator.clock(recheckAt))"))
                setSession(latest)
            } else if !service.isAuthorized {
                latest.events.append(JournalEvent(date: Date(), text: "Разрешение на будильники выключено во время проверки, повторный звонок поставить нельзя"))
                finish(latest, outcome: .failed)
            } else {
                latest.events.append(JournalEvent(date: Date(), text: "Повторный звонок не удалось поставить из-за сбоя системы, списания нет"))
                finish(latest, outcome: .technical)
            }
        }
    }

    /// Задание не может быть выполнено (например, нет камеры): переключаемся на печать, срок прежний.
    func switchToTyping(reason: String) {
        guard var current = session, current.phase == .task, current.taskKind != .typing else { return }
        current.taskKind = .typing
        current.events.append(JournalEvent(date: TrustedClock.now, text: reason))
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
        if let recheck = finished.recheckDate {
            DeadlineNotifications.cancelRecheck(alarmID: finished.alarmID, recheck: recheck)
        }
        emit(outcome == .success ? .recheckDone : .failed, session: finished, at: TrustedClock.now)
        let before = ProgressEngine.compute(entries: JournalStore.shared.realEntries, challenges: ChallengeStore.shared.challenges)

        let entry = JournalEntry(
            date: finished.originalRing ?? finished.startDate,
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
        let wasOnTaskScreen = finished.phase == .task
        setSession(nil)
        JournalStore.shared.add(entry)

        if let reference = finished.paymentRef {
            let amount = finished.stake
            PaymentsStore.shared.markOutcome(reference: reference, success: outcome == .success, amount: amount)
            Task { await PaymentsStore.shared.settle(reference: reference, success: outcome == .success, amount: amount) }
        }

        if outcome == .success {
            pendingMornings.append(MorningState(
                entryID: entry.id,
                module: finished.module,
                xpBefore: before.xp,
                levelBefore: before.level,
                badgesBefore: Set(before.unlocked.map(\.id)),
                treeStageBefore: before.tree.stage,
                treeIndexBefore: before.tree.index,
                flowersBefore: before.tree.flowers,
                fruitsBefore: before.tree.fruits,
                startedAt: Date()
            ))
        }

        startQueued(finished.queuedAlarmIDs ?? [], rings: finished.queuedRings ?? [:], now: TrustedClock.now)

        // Экран задания закроется сам; утро покажется после этого (см. RootView). Иначе показываем сразу.
        if !wasOnTaskScreen { presentPendingMorning() }
        Task { await DeadlineNotifications.refresh() }
    }

    /// Показывает отложенный утренний экран, если сейчас не идёт задание.
    func presentPendingMorning() {
        guard session == nil, morning == nil, !pendingMornings.isEmpty else { return }
        morning = pendingMornings.removeFirst()
    }

    /// Если приложение закрыли сразу после начала утра, блокировка ставки могла не успеть пройти.
    private func resumeHoldIfNeeded() {
        guard let current = session, let reference = current.paymentRef, current.stake > 0,
              !PaymentsStore.shared.hasHold(reference) else { return }
        let amount = current.stake
        Task { await PaymentsStore.shared.hold(amount: amount, reference: reference) }
    }

    // MARK: - Сверка пропущенных звонков

    /// Находит утра, когда задание так и не начали, и записывает их в журнал.
    /// Проверяются звонки, у которых уже вышло время на задание; отметка сверки сдвигается
    /// ровно до проверенного момента, поэтому ни один звонок не теряется.
    func reconcile(now: Date = TrustedClock.now) {
        reloadIfNeeded()
        evaluate(now)
        lateStart(now)
        resumeHoldIfNeeded()
        // Приложение закрыли раньше, чем встал повторный звонок: ставим его снова.
        if let current = session, current.phase == .waiting, current.stage == 1, current.recheckAlarmID == nil,
           let recheck = current.recheckDate, recheck.timeIntervalSince(now) > 5 {
            armRecheck(current, at: recheck)
        }

        let defaults = UserDefaults.standard
        let window = WakeRules.windowSeconds
        let checkUntil = now.addingTimeInterval(-window)
        let context = self.context

        if let lastCheck = defaults.object(forKey: WakeCoordinator.lastReconcileKey) as? Date {
            if checkUntil > lastCheck {
                // Проспанное утро записывается у любого будильника с заданием, со ставкой и без.
                // Времена звонков считаются и по текущему поясу, и по ожидавшимся при постановке:
                // перевод часов не прячет утро, а одно утро не списывается дважды.
                for alarm in AlarmStore.shared.alarms where alarm.hasTask && alarm.isEnabled {
                    // Изменения будильника после звонка не делают тот звонок пропущенным.
                    let from = max(lastCheck, AlarmStore.changedAt(alarm))
                    guard checkUntil > from else { continue }
                    let candidates = ringCandidates(alarm, from: from, to: checkUntil)
                    let due = MissedMornings.due(candidates: candidates, after: from, until: checkUntil) { isCovered(alarm, $0) }
                    for passed in due {
                        // Если одно из времён стояло в системе, считаем по нему: будильник звонил.
                        let ring = passed.first { service.scheduleState(alarm, ring: $0) == .scheduled } ?? passed[0]
                        recordMissed(alarm: alarm, ring: ring)
                    }
                }
                defaults.set(checkUntil, forKey: WakeCoordinator.lastReconcileKey)
            }
        } else {
            defaults.set(checkUntil, forKey: WakeCoordinator.lastReconcileKey)
        }

        // Одноразовые будильники выключаются после срабатывания, когда их звонок уже проверен выше.
        for alarm in AlarmStore.shared.alarms where alarm.isEnabled {
            if let once = ScheduleCalculator.onceDate(for: alarm, context: context),
               once.addingTimeInterval(window + 60) <= now,
               session?.alarmID != alarm.id, !isQueued(alarm.id) {
                AlarmStore.shared.disableSilently(alarm.id)
            }
        }

        presentPendingMorning()
    }

    private func recordMissed(alarm: AlarmItem, ring: Date) {
        let window = WakeRules.windowSeconds
        var events = [JournalEvent(date: ring, text: "Время звонка по расписанию")]
        let outcome: Outcome
        // Правило без исключений: проспал — провал и списание. Прощений нет ни в первый, ни в следующий раз.
        // Не списывается только то, что было не по вине человека: будильник не стоял в системе из-за сбоя.

        let state = service.scheduleState(alarm, ring: ring)
        if state == .systemFailure {
            events.append(JournalEvent(date: ring, text: "Будильник не был поставлен в системе из-за сбоя, списания нет"))
            outcome = .technical
        } else if state == .permissionMissing {
            // Разрешение выключил сам человек: это его выбор, а не сбой.
            events.append(JournalEvent(date: ring, text: "Разрешение на будильники было выключено, будильник не прозвенел"))
            outcome = .failed
        } else if state == .notRefreshed {
            // Приложение не открывали дольше 10 дней: новые будильники по Фаджру или календарю не были поставлены.
            events.append(JournalEvent(date: ring, text: "Приложение не открывали дольше 10 дней, будильник не был поставлен"))
            outcome = .failed
        } else {
            events.append(JournalEvent(date: ring.addingTimeInterval(window), text: "Приложение не открывали, задание не выполнено"))
            outcome = .failed
        }

        let stake = AlarmStore.shared.isStakeActive(alarm) ? alarm.stakeAmount : 0
        let reference: UUID? = (outcome == .failed && stake > 0) ? UUID() : nil
        JournalStore.shared.add(JournalEntry(
            date: ring,
            alarmID: alarm.id,
            alarmTitle: alarm.displayTitle,
            timeText: WakeCoordinator.clock(ring),
            stake: stake,
            outcome: outcome,
            events: events,
            isTraining: PaymentsStore.shared.isTraining,
            module: alarm.effectiveModule,
            isPrayer: alarm.isPrayerRelated ? true : nil,
            taskKind: alarm.effectiveTask,
            paymentRef: reference
        ))
        if let reference {
            let amount = stake
            PaymentsStore.shared.markOutcome(reference: reference, success: false, amount: amount)
            Task { await PaymentsStore.shared.hold(amount: amount, reference: reference) }
        }
    }

    func finishMorning() {
        morning = nil
        // Следующее утро из очереди (если два будильника прозвенели подряд) — после закрытия этого экрана.
        if !pendingMornings.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                presentPendingMorning()
            }
        }
    }
}
