import Foundation

/// Фон будильника: готовый градиент или своё фото.
enum Wallpaper: Codable, Equatable {
    case gradient(Int)
    case photo(String) // имя файла в Documents/Wallpapers
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
    /// Ставка пока работает как тренировка: деньги не списываются.
    var stakeEnabled = false
    var stakeAmount = 500
    /// Когда создан. Нужно, чтобы не засчитывать провалы до создания.
    var createdAt: Date? = Date()
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
    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var repeatText: String {
        if weekdays.isEmpty { return "Один раз" }
        if weekdays.count == 7 { return "Каждый день" }
        if weekdays == [1, 2, 3, 4, 5] { return "По будням" }
        if weekdays == [6, 7] { return "По выходным" }
        return weekdays.sorted().map { Weekdays.short[$0 - 1] }.joined(separator: " ")
    }

    var displayTitle: String { label.isEmpty ? "Будильник" : label }

    func matchesWeekday(_ date: Date) -> Bool {
        if weekdays.isEmpty { return true }
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekdays.contains(Weekdays.ours(fromCalendar: weekday))
    }

    private func candidate(dayOffset: Int, from now: Date) -> Date? {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// Последнее срабатывание не позже `now`.
    func lastOccurrence(onOrBefore now: Date) -> Date? {
        for offset in 0...7 {
            if let date = candidate(dayOffset: -offset, from: now), date <= now, matchesWeekday(date) {
                return date
            }
        }
        return nil
    }

    /// Ближайшее срабатывание после `now`.
    func nextOccurrence(after now: Date) -> Date? {
        for offset in 0...8 {
            if let date = candidate(dayOffset: offset, from: now), date > now, matchesWeekday(date) {
                return date
            }
        }
        return nil
    }
}
