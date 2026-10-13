import Foundation

/// Фокус-сессия: человек выбирает от 30 до 120 минут и сразу начинает. Суммарно вне приложения
/// (в том числе с заблокированным экраном) можно провести не больше 5 минут.
struct FocusSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var minutes: Int
    var startedAt: Date
    /// Обязательство, ₽. 0 — сессия без обязательства.
    var stake: Int
    /// Накопленное время вне приложения.
    var away: TimeInterval = 0
    /// Когда человек ушёл из приложения. nil — приложение открыто.
    var leftAt: Date?
    var paymentRef: UUID?
    var events: [JournalEvent] = []

    var endsAt: Date { startedAt.addingTimeInterval(Double(minutes) * 60) }
}

enum FocusOutcome: Equatable {
    case completed
    /// Вне приложения дольше 5 минут за всю сессию.
    case tooLongAway
    /// Сессию завершили раньше времени, когда отменить её уже было нельзя.
    case endedEarly

    var isSuccess: Bool { self == .completed }

    var reason: String {
        switch self {
        case .completed: return "Вы провели в приложении всё время сессии"
        case .tooLongAway: return "Вне приложения больше 5 минут за сессию"
        case .endedEarly: return "Сессию завершили раньше времени"
        }
    }
}

/// Правила фокус-сессии: чистые функции, проверяются тестами.
enum FocusRules {
    static let minMinutes = 30
    static let maxMinutes = 120
    /// Сколько всего можно провести вне приложения (звонок, села зарядка и так далее).
    static let awayLimit: TimeInterval = 5 * 60
    /// Сколько после начала сессию можно отменить без последствий.
    static let cancelWindow: TimeInterval = 5 * 60

    static func clampMinutes(_ minutes: Int) -> Int {
        min(maxMinutes, max(minMinutes, minutes))
    }

    /// Сколько всего вне приложения на момент `now`. Время после конца сессии не считается.
    static func awayTotal(_ session: FocusSession, now: Date) -> TimeInterval {
        var total = session.away
        if let left = session.leftAt {
            total += max(0, min(now, session.endsAt).timeIntervalSince(left))
        }
        return total
    }

    static func canCancel(_ session: FocusSession, now: Date) -> Bool {
        now.timeIntervalSince(session.startedAt) <= cancelWindow
    }

    /// Итог или nil, если сессия ещё идёт. Строго больше 5 минут — провал, ровно 5 — ещё можно.
    static func resolve(_ session: FocusSession, now: Date) -> FocusOutcome? {
        if awayTotal(session, now: now) > awayLimit { return .tooLongAway }
        if now >= session.endsAt { return .completed }
        return nil
    }

    /// Когда лимит вне приложения был превышен (для записи в дневник).
    static func failureTime(_ session: FocusSession, now: Date) -> Date {
        guard let left = session.leftAt else { return now }
        return left.addingTimeInterval(max(0, awayLimit - session.away))
    }

    /// «4:05» или «1:02:03».
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
