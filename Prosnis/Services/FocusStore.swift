import Foundation
import SwiftUI
import UserNotifications

/// Итог фокус-сессии: показывается на экране, пока человек не нажмёт «Готово».
struct FocusResult: Identifiable, Equatable {
    let id = UUID()
    var minutes: Int
    var outcome: FocusOutcome
    var stake: Int
    var away: TimeInterval
}

/// Идущая фокус-сессия: хранение на диске, учёт времени вне приложения, итог и деньги.
@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()

    @Published private(set) var current: FocusSession?
    @Published var result: FocusResult?

    private let file = FileStore<FocusSession>("focus_session")
    private var loadFailed = false

    private static let endID = "focus-end"
    private static let warnID = "focus-warn"
    private static let lostID = "focus-lost"

    private init() {
        reload()
    }

    func reload() {
        let loaded = file.loadWithState()
        current = loaded.value
        loadFailed = loaded.state == .unreadable
        result = nil
    }

    func reloadIfNeeded() {
        if loadFailed { reload() }
    }

    /// Нужен ли полноэкранный показ: сессия идёт или её итог ещё не закрыт.
    var showsCover: Bool { current != nil || result != nil }

    private func save() {
        if let current { file.save(current) } else { file.delete() }
    }

    // MARK: - Начало и отмена

    /// Начинает сессию сразу. Возвращает текст ошибки или nil.
    func start(minutes: Int, stake: Int, now: Date = TrustedClock.now) -> String? {
        reloadIfNeeded()
        guard current == nil else { return "Фокус-сессия уже идёт." }
        guard !loadFailed else { return "Данные пока закрыты: разблокируйте телефон и повторите." }
        guard WakeCoordinator.shared.session == nil else { return "Сейчас идёт утренняя проверка. Начните сессию после неё." }
        guard (FocusRules.minMinutes...FocusRules.maxMinutes).contains(minutes) else {
            return "Длительность сессии — от \(FocusRules.minMinutes) до \(FocusRules.maxMinutes) минут."
        }
        guard stake == 0 || stake >= AppConfig.minObligation else {
            return "Минимальная сумма — \(AppConfig.minObligation) ₽."
        }
        var session = FocusSession(minutes: minutes, startedAt: now, stake: stake)
        session.paymentRef = stake > 0 ? UUID() : nil
        session.events = [JournalEvent(date: now, text: "Фокус-сессия на \(minutes) мин начата")]
        result = nil
        current = session
        save()
        schedule(Self.endID, title: "Фокус-сессия закончилась",
                 body: "Откройте приложение, чтобы засчитать её.", at: session.endsAt)
        return nil
    }

    /// Отмена без последствий: только в первые 5 минут.
    @discardableResult
    func cancel(now: Date = TrustedClock.now) -> Bool {
        guard let session = current, FocusRules.canCancel(session, now: now) else { return false }
        clear()
        return true
    }

    /// Завершить раньше времени: в первые 5 минут это отмена, потом — невыполнение.
    func endEarly(now: Date = TrustedClock.now) {
        guard let session = current else { return }
        if FocusRules.canCancel(session, now: now) {
            clear()
        } else {
            finish(session, outcome: .endedEarly, now: now)
        }
    }

    private func clear() {
        current = nil
        file.delete()
        removeNotifications()
    }

    // MARK: - Время вне приложения

    /// Приложение открылось, свернулось или экран заблокировался.
    func scenePhaseChanged(_ phase: ScenePhase, now: Date = TrustedClock.now) {
        if phase == .active {
            returned(now: now)
        } else {
            left(now: now)
        }
    }

    private func left(now: Date) {
        guard var session = current, session.leftAt == nil else { return }
        session.leftAt = now
        current = session
        save()
        scheduleAwayNotifications(session, now: now)
    }

    private func returned(now: Date) {
        removeAwayNotifications()
        // Время вышло или лимит превышен, пока приложение было закрыто: итог решается при возвращении.
        evaluate(now: now)
        guard var session = current, let left = session.leftAt else { return }
        let gap = max(0, min(now, session.endsAt).timeIntervalSince(left))
        session.away += gap
        session.leftAt = nil
        // Короткие переключения (центр управления, баннер) в дневник не пишем.
        if gap >= 10 {
            session.events.append(JournalEvent(
                date: now,
                text: "Вне приложения \(FocusRules.clock(gap)), всего \(FocusRules.clock(session.away)) из \(FocusRules.clock(FocusRules.awayLimit))"
            ))
        }
        current = session
        save()
    }

    /// Проверяет итог. Вызывается раз в секунду на экране сессии и при каждом открытии приложения.
    func evaluate(now: Date = TrustedClock.now) {
        guard let session = current, let outcome = FocusRules.resolve(session, now: now) else { return }
        finish(session, outcome: outcome, now: now)
    }

    // MARK: - Итог

    private func finish(_ session: FocusSession, outcome: FocusOutcome, now: Date) {
        var events = session.events
        let away = FocusRules.awayTotal(session, now: now)
        let at: Date
        switch outcome {
        case .completed: at = session.endsAt
        case .tooLongAway: at = FocusRules.failureTime(session, now: now)
        case .endedEarly: at = now
        }
        events.append(JournalEvent(date: at, text: outcome.reason))
        let success = outcome.isSuccess
        let charged = !success && session.stake > 0
        let reference: UUID? = charged ? (session.paymentRef ?? UUID()) : nil

        clear()
        result = FocusResult(minutes: session.minutes, outcome: outcome, stake: session.stake, away: away)
        JournalStore.shared.add(JournalEntry(
            id: session.id,
            date: session.startedAt,
            alarmTitle: "Фокус \(session.minutes) мин",
            timeText: Format.time(session.startedAt),
            stake: session.stake,
            outcome: success ? .success : .failed,
            events: events,
            isTraining: PaymentsStore.shared.isTraining,
            module: .study,
            paymentRef: reference,
            chargeSeen: charged ? false : nil,
            isPromise: true,
            kind: .focus
        ))
        if let reference {
            let amount = session.stake
            PaymentsStore.shared.markOutcome(reference: reference, success: false, amount: amount)
            Task { await PaymentsStore.shared.hold(amount: amount, reference: reference) }
        }
    }

    // MARK: - Уведомления

    private func schedule(_ id: String, title: String, body: String, at date: Date) {
        let delay = date.timeIntervalSinceNow
        guard delay > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// Пока человек вне приложения: предупреждение за 30 секунд до лимита и сообщение о провале.
    private func scheduleAwayNotifications(_ session: FocusSession, now: Date) {
        let remaining = FocusRules.awayLimit - session.away
        guard remaining > 5 else { return }
        let sum = session.stake > 0 ? " и спишется \(session.stake) ₽" : ""
        let lostAt = now.addingTimeInterval(remaining + 1)
        // Сессия закончится раньше, чем кончится лимит: предупреждать не о чем.
        guard lostAt < session.endsAt else { return }
        schedule(Self.warnID, title: "Вернитесь в Prosnis",
                 body: "Осталось меньше 30 секунд: иначе фокус-сессия не засчитается\(sum).",
                 at: now.addingTimeInterval(max(5, remaining - 30)))
        schedule(Self.lostID, title: "Фокус-сессия не засчитана",
                 body: "Вы были вне приложения больше 5 минут\(session.stake > 0 ? ". Спишется \(session.stake) ₽." : ".")",
                 at: lostAt)
    }

    private func removeAwayNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.warnID, Self.lostID])
    }

    private func removeNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.endID, Self.warnID, Self.lostID])
    }
}
