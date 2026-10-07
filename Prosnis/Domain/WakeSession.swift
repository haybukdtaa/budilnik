import Foundation

enum WakeRules {
    /// Сколько времени даётся на задание от звонка.
    static let windowSeconds: TimeInterval = 600
    /// Через сколько после выполнения задания звонит повторная проверка.
    static let recheckDelay: TimeInterval = 600
    /// За сколько до звонка будильник со ставкой закрыт для изменений.
    static let lockSeconds: TimeInterval = 2 * 3600
    /// Будильник из очереди старше этого уже не запускается: человек явно уснул, звонок идёт в пропуски.
    static let queueStaleSeconds: TimeInterval = 2 * windowSeconds + recheckDelay
    /// Сколько ждать, что повторный звонок сам откроет приложение, прежде чем начать проверку из приложения.
    static let recheckGraceSeconds: TimeInterval = 20

    /// Пора ли начать вторую проверку из самого приложения (если повторный звонок не открыл его).
    static func shouldStartRecheckInApp(recheckDate: Date, now: Date) -> Bool {
        now >= recheckDate.addingTimeInterval(recheckGraceSeconds) && now < recheckDate.addingTimeInterval(windowSeconds)
    }

    /// Не устарел ли будильник из очереди.
    static func isQueuedRingStale(_ ring: Date, now: Date) -> Bool {
        now.timeIntervalSince(ring) > queueStaleSeconds
    }
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
    /// Будильники, которые прозвенели во время этой проверки: их задание начнётся следом.
    var queuedAlarmIDs: [UUID]?
    /// Когда прозвенел каждый будильник из очереди (ключ — id будильника).
    var queuedRings: [String: Date]?
    /// Для задания, начатого из очереди: настоящее время звонка.
    var originalRing: Date?

    var deadline: Date { ringDate.addingTimeInterval(WakeRules.windowSeconds) }
}

/// Время, которому можно верить, даже если на телефоне перевели часы.
/// Считается от последней проверенной точки по часам, которые идут с загрузки телефона и не зависят от настроек времени.
/// После перезагрузки проверить нечем, поэтому полную защиту даст только сервер.
enum TrustedClock {
    /// Точка отсчёта: время в момент сверки, показания часов с загрузки и идентификатор загрузки.
    struct Anchor: Codable, Equatable {
        var wall: Date
        var mono: Double
        var boot: String
    }

    private static let anchorKey = "trustedClock.anchor"
    /// Расхождение меньше этого — обычный дрейф часов или синхронизация по сети.
    static let driftTolerance: TimeInterval = 120
    /// Дольше этого защищённое время не перекрывает часы телефона: без новой сверки не держимся за старую точку вечно.
    static let maxOverride: TimeInterval = 3 * 86400

    private static var monotonicSeconds: Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    /// Идентификатор текущей загрузки телефона: новый после каждой перезагрузки.
    static var bootSession: String {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
                return String(cString: buffer)
            }
        }
        // Запасной вариант: время загрузки ядра.
        var boottime = timeval()
        size = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 {
            return "boot-\(boottime.tv_sec)"
        }
        return ""
    }

    /// Чистая функция: какое время считать настоящим и какую точку отсчёта сохранить (nil — оставить прежнюю).
    static func resolve(wall: Date, mono: Double, boot: String, anchor: Anchor?) -> (now: Date, anchor: Anchor?) {
        let fresh = Anchor(wall: wall, mono: mono, boot: boot)
        // Нет точки, другая загрузка или счётчик пошёл заново: проверить нечем, верим часам телефона.
        guard let anchor, anchor.boot == boot, mono >= anchor.mono else { return (wall, fresh) }
        let elapsed = mono - anchor.mono
        let trusted = anchor.wall.addingTimeInterval(elapsed)
        if abs(trusted.timeIntervalSince(wall)) < driftTolerance { return (wall, fresh) }
        if elapsed > maxOverride { return (wall, fresh) }
        return (trusted, nil)
    }

    static var now: Date {
        let defaults = UserDefaults.standard
        let anchor = defaults.data(forKey: anchorKey).flatMap { try? JSONDecoder().decode(Anchor.self, from: $0) }
        let result = resolve(wall: Date(), mono: monotonicSeconds, boot: bootSession, anchor: anchor)
        if let fresh = result.anchor { save(fresh) }
        return result.now
    }

    /// Время с сервера — самое надёжное: ставим точку отсчёта по нему.
    static func anchorToServer(_ serverNow: Date) {
        save(Anchor(wall: serverNow, mono: monotonicSeconds, boot: bootSession))
    }

    private static func save(_ anchor: Anchor) {
        if let data = try? JSONEncoder().encode(anchor) {
            UserDefaults.standard.set(data, forKey: anchorKey)
        }
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
