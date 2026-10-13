import BackgroundTasks
import Foundation

/// Фоновая проверка шагов обещаний. Это «по возможности»: iOS сама решает, когда запустить приложение
/// (и запустит ли вообще, если фоновое обновление выключено). Надёжно шаги проверяются при открытии приложения.
enum PromiseBackground {
    static let identifier = "app.prosnis.alarm.promise-check"

    /// Регистрирует обработчик. Вызывается один раз при запуске, до его окончания.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            await PromiseStore.shared.reconcile(force: true)
            schedule()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Просит систему проверить шаги после окна ближайшего обещания. Если обещаний нет, запрос снимается.
    @MainActor
    static func schedule(now: Date = Date()) {
        let scheduler = BGTaskScheduler.shared
        let promises = PromiseStore.shared.promises
        guard !promises.isEmpty else {
            scheduler.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        // Ближайшее окно, которое ещё не проверено: через пару минут после его конца, но не чаще раза в 15 минут.
        let ends = promises.map { $0.end.addingTimeInterval(PromiseRules.grace + 60) }
        let next = ends.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = max(next, now.addingTimeInterval(15 * 60))
        try? scheduler.submit(request)
    }
}
