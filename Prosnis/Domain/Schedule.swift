import Foundation

/// Всё, от чего зависит время звонка, кроме самого будильника.
struct ScheduleContext {
    var prayer: PrayerSettings
    var calendar: Calendar = .current
}

/// Расчёт дат срабатывания с учётом дней недели, Фаджра и производственного календаря.
enum ScheduleCalculator {
    /// Время звонка в указанный день или nil, если в этот день будильник не звонит.
    static func ringDate(for alarm: AlarmItem, onDayOf day: Date, context: ScheduleContext) -> Date? {
        let calendar = context.calendar
        let start = calendar.startOfDay(for: day)

        switch alarm.effectiveHolidayMode {
        case .workCalendar:
            guard HolidayCalendarRU.isWorkingDay(start, calendar: calendar) else { return nil }
        case .skipHolidays:
            guard alarm.matchesWeekday(start, calendar: calendar),
                  !HolidayCalendarRU.isHolidayWeekday(start, calendar: calendar) else { return nil }
        case .off:
            guard alarm.matchesWeekday(start, calendar: calendar) else { return nil }
        }

        if let offset = alarm.fajrOffset {
            guard let fajr = PrayerTimes.day(for: start.addingTimeInterval(12 * 3600), settings: context.prayer).fajr else {
                return nil
            }
            return fajr.addingTimeInterval(Double(offset) * 60)
        }
        return calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: start)
    }

    /// Все срабатывания в промежутке (from, to].
    static func occurrences(for alarm: AlarmItem, from: Date, to: Date, context: ScheduleContext) -> [Date] {
        guard from < to else { return [] }
        let calendar = context.calendar
        var result: [Date] = []
        var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: from)) ?? from
        let lastDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
        while day <= lastDay {
            if let ring = ringDate(for: alarm, onDayOf: day, context: context), ring > from, ring <= to {
                result.append(ring)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted()
    }

    /// Последнее срабатывание не позже `now` (ищется за 10 дней назад).
    static func lastOccurrence(for alarm: AlarmItem, onOrBefore now: Date, context: ScheduleContext) -> Date? {
        occurrences(for: alarm, from: now.addingTimeInterval(-10 * 86400), to: now, context: context).last
    }

    /// Ближайшее срабатывание после `now` (ищется на 10 дней вперёд).
    static func nextOccurrence(for alarm: AlarmItem, after now: Date, context: ScheduleContext) -> Date? {
        occurrences(for: alarm, from: now, to: now.addingTimeInterval(10 * 86400), context: context).first
    }

    /// Единственное срабатывание одноразового будильника: первое после создания.
    static func onceDate(for alarm: AlarmItem, context: ScheduleContext) -> Date? {
        guard alarm.weekdays.isEmpty, alarm.effectiveHolidayMode != .workCalendar else { return nil }
        return nextOccurrence(for: alarm, after: alarm.createdAt ?? .distantPast, context: context)
    }

    /// Срабатывания, которые действительно будут (у одноразового только одно).
    static func effectiveOccurrences(for alarm: AlarmItem, from: Date, to: Date, context: ScheduleContext) -> [Date] {
        if let once = onceDate(for: alarm, context: context) {
            return once > from && once <= to ? [once] : []
        }
        return occurrences(for: alarm, from: from, to: to, context: context)
    }
}

/// Возможное время звонка одного утра. После смены часового пояса у утра бывает два времени:
/// ожидавшееся при постановке будильника и посчитанное по новому поясу.
struct RingCandidate: Codable, Equatable {
    var at: Date
    /// День утра «гггг-мм-дд» в том поясе, в котором время посчитано.
    var day: String
    /// Когда приложение впервые узнало об этом времени. nil — посчитано только что, при сверке.
    var recordedAt: Date?
}

/// Сверка пропущенных утр: одно утро будильника — не больше одного списания, как бы ни переводили часы.
enum MissedMornings {
    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func candidates(_ dates: [Date], calendar: Calendar, recordedAt: Date? = nil) -> [RingCandidate] {
        dates.map { RingCandidate(at: $0, day: dayLabel($0, calendar: calendar), recordedAt: recordedAt) }
    }

    /// Объединяет кандидатов; время в пределах минуты считается одним звонком.
    static func merged(_ first: [RingCandidate], _ second: [RingCandidate]) -> [RingCandidate] {
        var result = first
        for item in second where !result.contains(where: { abs($0.at.timeIntervalSince(item.at)) < 60 }) {
            result.append(item)
        }
        return result.sorted { $0.at < $1.at }
    }

    /// Утра, которые пора записать как пропущенные: для каждого — его прошедшие в (from, until] времена по возрастанию.
    /// Утро ждёт, пока у него есть время позже `until` (человек мог встать по нему), и не записывается,
    /// если хоть одно его время «закрыто»: есть запись в журнале, идёт задание или звонок ждёт в очереди.
    /// Какие времена утра действуют. Время, известное заранее (не позже чем за 2 часа до звонка), — обязательное.
    /// Время, появившееся позже (часовой пояс сменили в последние 2 часа), может быть только раньше обязательного:
    /// перевести часы и встать позже нельзя, как нельзя изменить будильник со ставкой за 2 часа до звонка.
    static func valid(_ group: [RingCandidate], lead: TimeInterval = WakeRules.lockSeconds) -> [RingCandidate] {
        let known = group.filter { candidate in
            candidate.recordedAt.map { $0 <= candidate.at.addingTimeInterval(-lead) } ?? false
        }
        guard let binding = known.map(\.at).min() else { return group }
        // Более позднее время действует, только если о нём знали ещё до начала 2 часов перед обязательным.
        return group.filter { candidate in
            candidate.at <= binding.addingTimeInterval(60)
                || candidate.recordedAt.map { $0 <= binding.addingTimeInterval(-lead) } ?? false
        }
    }

    static func due(candidates: [RingCandidate], after from: Date, until: Date, isCovered: (Date) -> Bool) -> [[Date]] {
        let groups = Dictionary(grouping: candidates, by: \.day)
        var result: [[Date]] = []
        for day in groups.keys.sorted() {
            let group = valid(groups[day] ?? [])
            let passed = group.map(\.at).filter { $0 > from && $0 <= until }.sorted()
            guard !passed.isEmpty else { continue }
            if group.contains(where: { $0.at > until }) { continue }
            if group.contains(where: { isCovered($0.at) }) { continue }
            result.append(passed)
        }
        return result
    }

    /// Есть ли утро, которое ещё не решено: время прошло (за последние полтора дня), а записи нет ни по одному его времени.
    static func hasUnresolved(candidates: [RingCandidate], now: Date, isCovered: (Date) -> Bool) -> Bool {
        let groups = Dictionary(grouping: candidates, by: \.day)
        return groups.values.map { valid($0) }.contains { group in
            group.contains { $0.at <= now && now.timeIntervalSince($0.at) < 36 * 3600 }
                && !group.contains { isCovered($0.at) }
        }
    }
}
