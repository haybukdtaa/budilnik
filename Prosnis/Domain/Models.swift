import Foundation

/// Фон будильника: готовый градиент или своё фото.
enum Wallpaper: Codable, Equatable, Hashable {
    case gradient(Int)
    case photo(String) // имя файла в Documents/Wallpapers
}

/// Чем человек доказывает, что проснулся.
enum TaskKind: String, Codable, CaseIterable, Identifiable {
    case typing, math, memory, qr, steps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typing: return "Напечатать предложение"
        case .math: return "Решить примеры"
        case .memory: return "Запомнить клетки"
        case .qr: return "Сканировать код"
        case .steps: return "Пройти шаги"
        }
    }

    var icon: String {
        switch self {
        case .typing: return "keyboard"
        case .math: return "plusminus"
        case .memory: return "square.grid.3x3"
        case .qr: return "qrcode.viewfinder"
        case .steps: return "figure.walk"
        }
    }

    /// Задание нельзя выполнить, лёжа в кровати.
    var requiresGettingUp: Bool { self == .qr || self == .steps }
}

/// Как будильник относится к выходным и праздникам.
enum HolidayMode: String, Codable, CaseIterable, Identifiable {
    case off            // звонит по выбранным дням
    case skipHolidays   // по выбранным дням, кроме праздников и перенесённых выходных
    case workCalendar   // только в рабочие дни по производственному календарю РФ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Не учитывать"
        case .skipHolidays: return "Пропускать праздники"
        case .workCalendar: return "Рабочие дни по календарю РФ"
        }
    }
}

struct AlarmItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour = 7
    var minute = 0
    /// 1 = понедельник ... 7 = воскресенье. Пусто = сработает один раз.
    var weekdays: Set<Int> = []
    var label = ""
    var isEnabled = true
    var soundID = "classic_beep"
    var wallpaper: Wallpaper = .gradient(0)
    /// Ставка. Списание идёт через платёжный модуль; сейчас он тренировочный.
    var stakeEnabled = false
    var stakeAmount = 500
    /// Задание для выключения без ставки (у будильника со ставкой задание есть всегда).
    var taskEnabled: Bool? = false
    /// Когда создан. Нужно, чтобы не засчитывать провалы до создания.
    var createdAt: Date? = Date()
    var updatedAt: Date? = Date()
    var module: WakeModule? = .basic
    var taskKind: TaskKind? = .typing
    /// Содержимое зарегистрированного QR- или штрихкода для задания «Сканировать код».
    var qrCode: String?
    var holidayMode: HolidayMode? = .off
    /// Смещение от времени Фаджра в минутах. nil = обычный будильник по часам.
    var fajrOffset: Int?
    /// Повторная проверка через 10 минут у будильника без ставки. Со ставкой она обязательна всегда.
    var recheckEnabled: Bool?

    /// Нужно ли выполнять задание, чтобы выключить будильник.
    var hasTask: Bool { stakeEnabled || taskEnabled == true }
    /// Будет ли повторная проверка (без учёта согласия на ставку: его проверяет WakeCoordinator).
    var wantsRecheck: Bool { stakeEnabled || recheckEnabled == true }
    var isFajr: Bool { fajrOffset != nil }
    var effectiveTask: TaskKind { taskKind ?? .typing }
    var effectiveModule: WakeModule { module ?? .basic }
    var effectiveHolidayMode: HolidayMode { holidayMode ?? .off }
    /// Время меняется по дням или есть исключения: системные будильники ставятся на конкретные даты.
    var needsDatedSchedule: Bool { isFajr || effectiveHolidayMode != .off }
    /// Сведения, по которым можно судить о религиозных взглядах. По умолчанию не покидают телефон.
    var isPrayerRelated: Bool { isFajr || effectiveModule == .prayer }
}

enum Weekdays {
    static let short = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    static func locale(_ number: Int) -> Locale.Weekday {
        switch number {
        case 1: return .monday
        case 2: return .tuesday
        case 3: return .wednesday
        case 4: return .thursday
        case 5: return .friday
        case 6: return .saturday
        default: return .sunday
        }
    }

    /// Календарный номер дня (1 = воскресенье) в наш (1 = понедельник).
    static func ours(fromCalendar weekday: Int) -> Int {
        (weekday + 5) % 7 + 1
    }
}

extension AlarmItem {
    var timeText: String {
        if let offset = fajrOffset {
            if offset == 0 { return "Фаджр" }
            return offset < 0 ? "Фаджр −\(-offset)" : "Фаджр +\(offset)"
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    var repeatText: String {
        if effectiveHolidayMode == .workCalendar { return "Рабочие дни РФ" }
        let base: String
        if weekdays.isEmpty {
            base = "Один раз"
        } else if weekdays.count == 7 {
            base = "Каждый день"
        } else if weekdays == [1, 2, 3, 4, 5] {
            base = "По будням"
        } else if weekdays == [6, 7] {
            base = "По выходным"
        } else {
            base = weekdays.sorted().map { Weekdays.short[$0 - 1] }.joined(separator: " ")
        }
        return effectiveHolidayMode == .skipHolidays ? base + ", без праздников" : base
    }

    var displayTitle: String { label.isEmpty ? "Будильник" : label }

    func matchesWeekday(_ date: Date, calendar: Calendar = .current) -> Bool {
        if weekdays.isEmpty { return true }
        let weekday = calendar.component(.weekday, from: date)
        return weekdays.contains(Weekdays.ours(fromCalendar: weekday))
    }
}
