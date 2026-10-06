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
    var taskKind: TaskKind = .typing
    /// Код, который нужно отсканировать (для задания «Сканировать код»).
    var qrCode: String?
    var module: WakeModule = .basic
    var isPrayer = false
    /// Ссылка на блокировку суммы ставки.
    var paymentRef: UUID?

    var deadline: Date { ringDate.addingTimeInterval(WakeRules.windowSeconds) }
}

/// Время, которому можно верить, даже если на телефоне перевели часы.
/// Считается от последней проверенной точки по часам, которые идут с загрузки телефона и не зависят от настроек времени.
/// После перезагрузки проверить нечем, поэтому полную защиту даст только сервер.
enum TrustedClock {
    private static let wallKey = "trustedClock.wall"
    private static let monoKey = "trustedClock.mono"

    private static var monotonicSeconds: Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    static var now: Date {
        let wall = Date()
        let mono = monotonicSeconds
        let defaults = UserDefaults.standard

        guard let anchorWall = defaults.object(forKey: wallKey) as? Date,
              defaults.object(forKey: monoKey) != nil else {
            anchor(wall, mono)
            return wall
        }
        let anchorMono = defaults.double(forKey: monoKey)
        if mono < anchorMono {
            // Телефон перезагружали.
            anchor(wall, mono)
            return wall
        }
        let trusted = anchorWall.addingTimeInterval(mono - anchorMono)
        if abs(trusted.timeIntervalSince(wall)) < 120 {
            // Обычный дрейф часов или синхронизация по сети.
            anchor(wall, mono)
            return wall
        }
        return trusted
    }

    private static func anchor(_ wall: Date, _ mono: Double) {
        UserDefaults.standard.set(wall, forKey: wallKey)
        UserDefaults.standard.set(mono, forKey: monoKey)
    }
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
