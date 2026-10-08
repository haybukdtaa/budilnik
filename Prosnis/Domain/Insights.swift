import Foundation

/// «Часы, которые вы выиграли»: насколько раньше человек встаёт, чем вставал до приложения.
enum HoursWon {
    /// Минут утра, выигранных в это утро (0, если встал не раньше прежнего времени).
    static func minutes(for entry: JournalEntry, usualWakeMinutes: Int, calendar: Calendar = .current) -> Int {
        guard entry.counts, entry.outcome == .success else { return 0 }
        let parts = calendar.dateComponents([.hour, .minute], from: entry.date)
        let woke = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return max(0, usualWakeMinutes - woke)
    }

    /// Сумма выигранных минут по утрам в промежутке [from, to). Несколько будильников в одно утро считаются один раз — по самому раннему.
    static func total(entries: [JournalEntry], usualWakeMinutes: Int, from: Date, to: Date, calendar: Calendar = .current) -> Int {
        var best: [Date: Int] = [:]
        for entry in entries where entry.date >= from && entry.date < to {
            let gained = minutes(for: entry, usualWakeMinutes: usualWakeMinutes, calendar: calendar)
            guard gained > 0 else { continue }
            let day = calendar.startOfDay(for: entry.date)
            best[day] = max(best[day] ?? 0, gained)
        }
        return best.values.reduce(0, +)
    }

    /// На что похоже это время: фильмы по 2 часа, тренировки по часу, книги по 6 часов.
    static func equivalents(minutes: Int) -> [String] {
        guard minutes >= 60 else { return [] }
        var list: [String] = []
        let films = minutes / 120
        let workouts = minutes / 60
        let books = minutes / 360
        if films > 0 { list.append("\(films) \(plural(films, "фильм", "фильма", "фильмов"))") }
        list.append("\(workouts) \(plural(workouts, "тренировка", "тренировки", "тренировок")) по часу")
        if books > 0 { list.append("\(books) \(plural(books, "книга", "книги", "книг"))") }
        return list
    }

    static func text(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) мин" }
        return rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
}

/// Итоги недели: сколько утр, сколько выиграно времени, как выросло дерево, сколько сохранено ставок.
struct WeeklySummary: Equatable {
    var weekStart: Date
    var mornings = 0
    var successes = 0
    var failures = 0
    /// Успешные утра с повторной проверкой.
    var rechecked = 0
    var minutesWon = 0
    /// Сохранённые ставки: сумма ставок утр, когда человек встал.
    var saved = 0
    /// Успешных утр на прошлой неделе — для сравнения.
    var previousSuccesses = 0

    var isBetterThanPrevious: Bool { successes > previousSuccesses }

    /// Неделя с понедельника по воскресенье, в которую входит `now`.
    static func weekStart(for now: Date, calendar: Calendar = .current) -> Date {
        var monday = calendar
        monday.firstWeekday = 2
        return monday.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    static func compute(entries: [JournalEntry], now: Date, usualWakeMinutes: Int?, calendar: Calendar = .current) -> WeeklySummary {
        let start = weekStart(for: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let counted = entries.filter(\.counts)
        let week = counted.filter { $0.date >= start && $0.date < end }

        var summary = WeeklySummary(weekStart: start)
        summary.mornings = week.count
        summary.successes = week.filter { $0.outcome == .success }.count
        summary.failures = week.filter { $0.outcome == .failed }.count
        summary.rechecked = week.filter { $0.outcome == .success && $0.rechecked != false }.count
        summary.saved = week.filter { $0.outcome == .success }.reduce(0) { $0 + $1.stake }
        if let usual = usualWakeMinutes {
            summary.minutesWon = HoursWon.total(entries: week, usualWakeMinutes: usual, from: start, to: end, calendar: calendar)
        }
        summary.previousSuccesses = counted.filter { $0.date >= previousStart && $0.date < start && $0.outcome == .success }.count
        return summary
    }
}
