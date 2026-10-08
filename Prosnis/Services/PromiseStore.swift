import CoreMotion
import Foundation
import UserNotifications

/// Ответ можно отдать только один раз: либо данные, либо таймаут.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Чтение шагов с телефона. Данные не покидают устройство.
@MainActor
enum StepCounting {
    static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }
    /// Доступ к данным о движении уже выдан.
    static var hasAccess: Bool { CMPedometer.authorizationStatus() == .authorized }
    /// Дольше этого запрос к счётчику не ждём.
    static let timeout: TimeInterval = 15

    /// Просит доступ к данным о движении (пробным запросом). false — доступа нет.
    static func requestAccess() async -> Bool {
        guard isAvailable else { return false }
        switch CMPedometer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            let now = Date()
            pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, error in
                withExtendedLifetime(pedometer) { continuation.resume(returning: error == nil) }
            }
        }
    }

    /// Шаги за промежуток [from, to].
    static func read(from: Date, to: Date) async -> StepRead {
        guard isAvailable else { return .unavailable }
        // Системный запрос доступа при чтении не показываем: доступ спрашивается при создании обещания.
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted, .notDetermined: return .denied
        default: break
        }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                withExtendedLifetime(pedometer) {
                    if let data {
                        once.resume(.steps(data.numberOfSteps.intValue))
                    } else if let error = error as NSError?, error.domain == "CMErrorDomain",
                              error.code == 105 { // CMErrorMotionActivityNotAuthorized
                        once.resume(.denied)
                    } else {
                        once.resume(.unavailable)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.unavailable) }
        }
    }
}

/// Обещания по шагам: хранение, проверка, уведомления и запись итога в дневник.
@MainActor
final class PromiseStore: ObservableObject {
    static let shared = PromiseStore()

    @Published private(set) var promises: [StepPromise] = []
    /// Шаги, насчитанные в идущем окне (для показа на карточке).
    @Published private(set) var liveSteps: [UUID: Int] = [:]

    private let file = FileStore<[StepPromise]>("promises")
    private var loadFailed = false
    private var isReconciling = false
    private var lastCheck: [UUID: Date] = [:]

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        promises = (result.value ?? []).sorted { $0.start < $1.start }
        loadFailed = result.state == .unreadable
        liveSteps = [:]
    }

    func reloadIfNeeded() {
        if loadFailed { reload() }
    }

    private func save() {
        guard !loadFailed else { return }
        file.save(promises)
    }

    /// Обещание, которое скоро начнётся или идёт: пока оно есть, данные удалять нельзя.
    var hasActive: Bool {
        let now = TrustedClock.now
        return promises.contains { PromiseRules.isLocked($0, now: now) }
    }

    // MARK: - Создание и удаление

    /// Создаёт обещание. Возвращает текст ошибки или nil.
    func add(_ promise: StepPromise) -> String? {
        let now = TrustedClock.now
        guard promise.start >= now.addingTimeInterval(PromiseRules.minLead) else {
            return "Начало должно быть хотя бы через 15 минут."
        }
        guard promise.end > promise.start, promise.minSteps > 0, promise.stake > 0 else {
            return "Проверьте окно, число шагов и ставку."
        }
        guard !loadFailed else { return "Данные пока закрыты: разблокируйте телефон и повторите." }
        promises.append(promise)
        promises.sort { $0.start < $1.start }
        save()
        Task { await scheduleNotifications(promise) }
        return nil
    }

    /// Удаляет обещание, если оно ещё не закрыто (раньше чем за 2 часа до начала).
    func delete(_ promise: StepPromise) -> String? {
        guard !PromiseRules.isLocked(promise, now: TrustedClock.now) else {
            return "Обещание нельзя изменить или удалить за 2 часа до начала и пока оно идёт."
        }
        promises.removeAll { $0.id == promise.id }
        save()
        cancelNotifications(promise.id)
        return nil
    }

    // MARK: - Проверка

    /// Читает шаги и решает обещания, у которых окно началось. Идущее окно проверяется раз в минуту.
    func reconcile(now: Date = TrustedClock.now, force: Bool = false) async {
        reloadIfNeeded()
        guard !isReconciling, !promises.isEmpty else { return }
        isReconciling = true
        defer { isReconciling = false }

        for promise in promises where now >= promise.start {
            guard promises.contains(where: { $0.id == promise.id }) else { continue }
            var read: StepRead?
            if now <= PromiseRules.verifyDeadline(promise) {
                // Идущее окно — раз в минуту, после окна — раз в пять минут (если чтение не удаётся).
                let gap: TimeInterval = now < promise.end ? 55 : 300
                if !force, let last = lastCheck[promise.id], now.timeIntervalSince(last) < gap { continue }
                lastCheck[promise.id] = now
                read = await StepCounting.read(from: promise.start, to: min(now, promise.end))
                switch read {
                case .steps(let count)?:
                    liveSteps[promise.id] = count
                    mark(promise.id, readFailed: false)
                case .denied?:
                    mark(promise.id, readFailed: false)
                case .unavailable?:
                    mark(promise.id, readFailed: true)
                case nil:
                    break
                }
            }
            guard let current = promises.first(where: { $0.id == promise.id }) else { continue }
            if let resolution = PromiseRules.resolve(current, read: read, now: now) {
                apply(resolution, to: current)
            }
        }
    }

    private func mark(_ id: UUID, readFailed: Bool) {
        guard let index = promises.firstIndex(where: { $0.id == id }), promises[index].readFailed != readFailed else { return }
        promises[index].readFailed = readFailed
        save()
    }

    /// Итог обещания: запись в дневник, деньги, уведомления.
    private func apply(_ resolution: PromiseResolution, to promise: StepPromise) {
        let outcome: Outcome
        var reference: UUID?
        switch resolution {
        case .kept: outcome = .success
        case .technical: outcome = .technical
        case .broken:
            outcome = .failed
            reference = UUID()
        }
        var events = [JournalEvent(date: promise.start, text: "Обещание: \(promise.windowText), не меньше \(promise.minSteps) шагов")]
        events.append(JournalEvent(date: TrustedClock.now, text: PromiseRules.eventText(resolution, promise: promise)))
        // Запись в дневник — первой, с номером обещания: если приложение закроют между шагами, итог не потеряется и не задвоится.
        if !JournalStore.shared.entries.contains(where: { $0.id == promise.id }) {
        JournalStore.shared.add(JournalEntry(
            id: promise.id,
            date: promise.start,
            alarmTitle: promise.title,
            timeText: promise.windowText,
            stake: promise.stake,
            outcome: outcome,
            events: events,
            isTraining: PaymentsStore.shared.isTraining,
            module: .sport,
            taskKind: .steps,
            paymentRef: reference,
            chargeSeen: outcome == .failed ? false : nil,
            isPromise: true
        ))
        if let reference {
            let amount = promise.stake
            PaymentsStore.shared.markOutcome(reference: reference, success: false, amount: amount)
            Task { await PaymentsStore.shared.hold(amount: amount, reference: reference) }
        }
        }
        promises.removeAll { $0.id == promise.id }
        liveSteps[promise.id] = nil
        lastCheck[promise.id] = nil
        save()
        cancelNotifications(promise.id)
    }

    // MARK: - Уведомления (тихие)

    /// Дни после окна, когда напоминаем открыть приложение (крайний срок проверки — через 6 дней).
    private static let reminderDays = [1, 3, 5]

    private func ids(_ id: UUID) -> [String] {
        ["promise-start-\(id.uuidString)", "promise-end-\(id.uuidString)"]
            + PromiseStore.reminderDays.map { "promise-check-\($0)-\(id.uuidString)" }
    }

    private func scheduleNotifications(_ promise: StepPromise) async {
        let center = UNUserNotificationCenter.current()
        func add(_ id: String, _ title: String, _ body: String, at date: Date) async {
            guard date > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            ))
        }
        let names = ids(promise.id)
        await add(names[0], "Время бежать",
                  "«\(promise.title)»: нужно \(promise.minSteps) шагов до \(Format.time(promise.end)).", at: promise.start)
        await add(names[1], "Окно закончилось",
                  "Откройте приложение — посчитаем шаги.", at: promise.end)
        for (index, days) in PromiseStore.reminderDays.enumerated() {
            let last = days == PromiseStore.reminderDays.last
            await add(names[2 + index], "Шаги ещё не посчитаны",
                      last ? "Завтра шаги за «\(promise.title)» уже нельзя будет проверить: откройте приложение сегодня."
                           : "Откройте приложение — посчитаем шаги за «\(promise.title)».",
                      at: promise.end.addingTimeInterval(Double(days) * 86400 + 9 * 3600))
        }
    }

    private func cancelNotifications(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids(id))
    }

    /// Убирает уведомления всех обещаний (при удалении данных).
    func cancelAllNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("promise-") })
    }

    /// После запуска: восстановить уведомления тех обещаний, у которых они ещё впереди.
    func restoreNotifications() async {
        for promise in promises where promise.end > Date() { await scheduleNotifications(promise) }
    }
}
