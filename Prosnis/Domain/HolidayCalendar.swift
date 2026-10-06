import Foundation

/// Производственный календарь РФ: праздники по статье 112 ТК РФ, автоматический перенос
/// праздников с выходных и переносы по постановлениям правительства.
/// Переносы известны на 2026 год и на 2027 год (постановление № 1187 от 17.09.2026).
/// Для других лет считаются только праздники и автоматические переносы.
enum HolidayCalendarRU {
    private struct DayKey: Hashable {
        let year: Int, month: Int, day: Int
    }

    private static let holidays: [(Int, Int)] = [
        (1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7), (1, 8),
        (2, 23), (3, 8), (5, 1), (5, 9), (6, 12), (11, 4),
    ]

    /// Переносы по постановлениям: (откуда, куда). «Откуда» становится рабочим, если это не праздник.
    private static let transfers: [Int: [((Int, Int), (Int, Int))]] = [
        2026: [((1, 3), (1, 9)), ((1, 4), (12, 31))],
        2027: [((1, 2), (11, 5)), ((1, 3), (12, 31)), ((2, 20), (2, 22))],
    ]

    static func hasTransferData(for year: Int) -> Bool { transfers[year] != nil }

    private static var cache: [Int: (off: Set<DayKey>, workingWeekends: Set<DayKey>)] = [:]
    private static let lock = NSLock()

    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func yearData(_ year: Int) -> (off: Set<DayKey>, workingWeekends: Set<DayKey>) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[year] { return cached }

        let calendar = gregorian
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        func key(_ value: Date) -> DayKey {
            let parts = calendar.dateComponents([.year, .month, .day], from: value)
            return DayKey(year: parts.year!, month: parts.month!, day: parts.day!)
        }
        func isWeekend(_ value: Date) -> Bool {
            let weekday = calendar.component(.weekday, from: value)
            return weekday == 1 || weekday == 7
        }

        var off = Set<DayKey>()
        var day = date(1, 1)
        while calendar.component(.year, from: day) == year {
            if isWeekend(day) { off.insert(key(day)) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        let holidayDates = holidays.map { date($0.0, $0.1) }
        let holidayKeys = Set(holidayDates.map(key))
        off.formUnion(holidayKeys)

        // Праздник на выходном (кроме январских) переносится на следующий рабочий день.
        for holiday in holidayDates.sorted() where calendar.component(.month, from: holiday) != 1 && isWeekend(holiday) {
            var next = calendar.date(byAdding: .day, value: 1, to: holiday)!
            while isWeekend(next) || off.contains(key(next)) {
                next = calendar.date(byAdding: .day, value: 1, to: next)!
            }
            off.insert(key(next))
        }

        var workingWeekends = Set<DayKey>()
        for (from, to) in transfers[year] ?? [] {
            off.insert(key(date(to.0, to.1)))
            let fromKey = key(date(from.0, from.1))
            if !holidayKeys.contains(fromKey) {
                off.remove(fromKey)
                workingWeekends.insert(fromKey)
            }
        }

        let result = (off, workingWeekends)
        cache[year] = result
        return result
    }

    private static func key(of date: Date, in calendar: Calendar) -> DayKey {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DayKey(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Рабочий ли день по производственному календарю (дата берётся в часовом поясе `calendar`).
    static func isWorkingDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        let dayKey = key(of: date, in: calendar)
        return !yearData(dayKey.year).off.contains(dayKey)
    }

    /// Праздник или перенесённый выходной, выпавший на будний день.
    static func isHolidayWeekday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return false }
        return !isWorkingDay(date, calendar: calendar)
    }

    /// Рабочая суббота или воскресенье по переносу.
    static func isWorkingWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        let dayKey = key(of: date, in: calendar)
        return yearData(dayKey.year).workingWeekends.contains(dayKey)
    }
}
