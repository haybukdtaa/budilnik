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
