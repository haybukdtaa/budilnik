import Foundation

/// Обещание по шагам: «в 22:00 иду бегать, не меньше 5000 шагов до 23:30». Создаётся один раз, не повторяется.
struct StepPromise: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Пробежка"
    var start: Date
    var end: Date
    var minSteps = 5000
    var stake = 500
    var createdAt = Date()
    /// После окна не удалось прочитать шаги (сбой телефона): запоминаем, чтобы не списать зря.
    var readFailed: Bool?

    var windowText: String {
        "\(Format.time(start))–\(Format.time(end))"
    }
}

/// Что вернул счётчик шагов за окно.
enum StepRead: Equatable {
    case steps(Int)
    /// Нет доступа к данным о движении: человек выключил его сам.
    case denied
    /// Доступ ещё не спрашивали (например, сбросили все разрешения в настройках iPhone). Это не отказ.
    case needsAccess
    /// Не удалось прочитать (сбой телефона или счётчика).
    case unavailable
}

enum PromiseBrokenReason: Equatable {
    case notEnough
    case denied
    case unverified
}

enum PromiseResolution: Equatable {
    case kept(steps: Int)
    case broken(PromiseBrokenReason, steps: Int?)
    /// Шаги прочитать не удалось из-за сбоя телефона: ставка не списывается.
    case technical
}

/// Правила обещаний по шагам: чистые функции, проверяются тестами.
enum PromiseRules {
    /// За сколько до начала окна обещание закрыто для изменений (как будильник со ставкой).
    static let lockSeconds: TimeInterval = WakeRules.lockSeconds
    /// Раньше чем за столько до начала создавать обещание нельзя.
    static let minLead: TimeInterval = 15 * 60
    /// Шаги за окно проверяются не позже чем через столько дней: телефон хранит данные о шагах неделю.
    static let verifyDays = 6
    static let windows: [Int] = [30, 60, 90, 120, 180]
    /// Сколько ждать после конца окна, прежде чем решать «не хватило»: последние шаги доходят до счётчика не сразу.
    static let grace: TimeInterval = 120

    static func isLocked(_ promise: StepPromise, now: Date) -> Bool {
        now >= promise.start.addingTimeInterval(-lockSeconds)
    }

    static func verifyDeadline(_ promise: StepPromise) -> Date {
        promise.end.addingTimeInterval(Double(verifyDays) * 86400)
    }

    /// Итог обещания или nil, если оно ещё не решено.
    /// - `read`: шаги с начала окна до «сейчас» (или до конца окна, если оно закончилось).
    static func resolve(_ promise: StepPromise, read: StepRead?, now: Date) -> PromiseResolution? {
        guard now >= promise.start else { return nil }
        // Данные о шагах уже стёрты: если окно не проверили вовремя, это на человеке; сбой телефона — нет.
        if now > verifyDeadline(promise) {
            return promise.readFailed == true ? .technical : .broken(.unverified, steps: nil)
        }
        switch read {
        case .steps(let count):
            if count >= promise.minSteps { return .kept(steps: count) }
            return now >= promise.end.addingTimeInterval(grace) ? .broken(.notEnough, steps: count) : nil
        case .denied:
            return now >= promise.end.addingTimeInterval(grace) ? .broken(.denied, steps: nil) : nil
        case .unavailable, .needsAccess, nil:
            return nil
        }
    }

    /// Как человеку объяснить итог.
    static func eventText(_ resolution: PromiseResolution, promise: StepPromise) -> String {
        switch resolution {
        case .kept(let steps): return "Насчитано \(steps) шагов из \(promise.minSteps): обещание выполнено"
        case .broken(.notEnough, let steps): return "Насчитано \(steps ?? 0) шагов из \(promise.minSteps)"
        case .broken(.denied, _): return "Нет доступа к данным о движении: шаги не посчитать"
        case .broken(.unverified, _): return "Шаги не проверили в течение \(verifyDays) дней после окна"
        case .technical: return "Не удалось прочитать шаги из-за сбоя телефона, списания нет"
        }
    }
}
