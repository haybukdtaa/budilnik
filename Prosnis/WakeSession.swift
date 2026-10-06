import Foundation

enum WakeRules {
    /// Сколько времени даётся на задание от звонка.
    static let windowSeconds: TimeInterval = 600
    /// Через сколько после выполнения задания звонит повторная проверка.
    static let recheckDelay: TimeInterval = 600
    /// За сколько до звонка будильник со ставкой закрыт для изменений.
    static let lockSeconds: TimeInterval = 2 * 3600
}

enum WakePhase: String, Codable {
    case task      // нужно печатать предложение
    case waiting   // ждём повторного звонка
}

/// Одно утро, пока оно не закончилось успехом или провалом.
struct WakeSession: Codable {
    var alarmID: UUID
    var alarmTitle: String
    var timeText: String
    var stake: Int
    var wallpaper: Wallpaper
    var soundID: String
    var startDate: Date        // когда прозвенел первый звонок
    var stage: Int             // 1 или 2
    var phase: WakePhase
    var ringDate: Date         // когда прозвенел звонок текущего этапа
    var recheckDelay: TimeInterval = WakeRules.recheckDelay
    var recheckDate: Date?
    var recheckAlarmID: UUID?
    var sentence: String
    var events: [JournalEvent]
    var isDemo = false

    var deadline: Date { ringDate.addingTimeInterval(WakeRules.windowSeconds) }
}

enum Bedtime {
    private static let key = "lastBedtimeCheck"

    static func recordCheck(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: key)
    }

    static var lastCheck: Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    /// Была ли вечерняя проверка не раньше, чем за `within` секунд до `date`.
    static func wasChecked(before date: Date, within: TimeInterval = 20 * 3600) -> Bool {
        guard let last = lastCheck else { return false }
        return last <= date && date.timeIntervalSince(last) <= within
    }
}
