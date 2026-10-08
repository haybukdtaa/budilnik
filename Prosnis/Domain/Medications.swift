import Foundation

/// Форма лекарства: только для иконки и слов.
enum MedForm: String, Codable, CaseIterable, Identifiable {
    case tablet, capsule, drops, syrup, injection, inhaler

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tablet: return "Таблетка"
        case .capsule: return "Капсула"
        case .drops: return "Капли"
        case .syrup: return "Сироп"
        case .injection: return "Укол"
        case .inhaler: return "Ингаляция"
        }
    }

    var icon: String {
        switch self {
        case .tablet: return "pills"
        case .capsule: return "pill"
        case .drops: return "drop"
        case .syrup: return "cup.and.saucer"
        case .injection: return "syringe"
        case .inhaler: return "wind"
        }
    }
}

/// Как принимать относительно еды.
enum MealRelation: String, Codable, CaseIterable, Identifiable {
    case any, before, during, after

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Не важно"
        case .before: return "До еды"
        case .during: return "Во время"
        case .after: return "После еды"
        }
    }

    /// Подсказка в напоминании (nil — без подсказки).
    var hint: String? {
        switch self {
        case .any: return nil
        case .before: return "до еды"
        case .during: return "во время еды"
        case .after: return "после еды"
        }
    }
}

/// Лекарство и схема приёма. Хранится только на телефоне: это сведения о здоровье.
struct Medication: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    /// Как человек сам записал дозу: «1 таблетка», «10 капель».
    var dose = ""
    var form: MedForm = .tablet
    /// Время приёмов в минутах от полуночи (по часам). Пусто, если приём «после подъёма».
    var times: [Int] = [9 * 60]
    /// Через сколько минут после подъёма (вместо времени по часам).
    var afterWakeMinutes: Int?
    /// Если в этот день утром не было будильника: во сколько напомнить (минуты от полуночи).
    var afterWakeFallback = 9 * 60
    var meal: MealRelation = .any
    /// Первый день курса.
    var startDate = Date()
    /// Последний день курса. nil — принимать постоянно.
    var endDate: Date?
    /// Сколько единиц осталось в упаковке. nil — запас не считаем.
    var stock: Int?
    /// Сколько единиц уходит за один приём.
    var unitsPerDose = 1
    /// Громко, как будильник (звонит и в беззвучном режиме), или тихое уведомление.
    var loud = false

    var isAfterWake: Bool { afterWakeMinutes != nil }
    var dosesPerDay: Int { isAfterWake ? 1 : max(times.count, 1) }

    /// На сколько дней хватит запаса (nil — запас не считаем).
    var daysLeft: Int? {
        guard let stock else { return nil }
        return stock / max(unitsPerDose * dosesPerDay, 1)
    }

    static let refillDays = 5
    var needsRefill: Bool { daysLeft.map { $0 <= Medication.refillDays } ?? false }
}

enum DoseStatus: String, Codable {
    case taken, skipped
}

/// Отметка о приёме. Пропуск без отметки записи не имеет: он считается сам, через два часа после времени.
struct DoseRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var medicationID: UUID
    /// На какое время был назначен приём.
    var scheduled: Date
    var status: DoseStatus
    var at: Date
}

/// Один назначенный приём.
struct Dose: Identifiable, Equatable {
    var medicationID: UUID
    var scheduled: Date

    var id: String { "\(medicationID.uuidString)-\(Int(scheduled.timeIntervalSince1970))" }
}

/// Что с приёмом сейчас.
enum DoseState: Equatable {
    case taken(Date), skipped, missed, due, upcoming
}

/// Расписание приёмов: чистые функции, проверяются тестами.
enum MedSchedule {
    /// Сколько ждать отметки, прежде чем приём считается пропущенным.
    static let missedAfter: TimeInterval = 2 * 3600
    /// За сколько до времени приём уже можно отметить.
    static let dueBefore: TimeInterval = 30 * 60

    /// Приёмы лекарства в промежутке [from, to). `wakeTimes` — время подъёма по дням (начало дня → момент подъёма).
    static func doses(for med: Medication, from: Date, to: Date, wakeTimes: [Date: Date] = [:], calendar: Calendar = .current) -> [Dose] {
        let firstDay = calendar.startOfDay(for: med.startDate)
        var day = max(calendar.startOfDay(for: from), firstDay)
        var result: [Dose] = []
        while day < to {
            if let end = med.endDate, day > calendar.startOfDay(for: end) { break }
            for moment in moments(for: med, on: day, wakeTimes: wakeTimes, calendar: calendar)
            where moment >= from && moment < to && moment >= med.startDate.addingTimeInterval(-60) {
                result.append(Dose(medicationID: med.id, scheduled: moment))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.scheduled < $1.scheduled }
    }

    static func moments(for med: Medication, on day: Date, wakeTimes: [Date: Date], calendar: Calendar) -> [Date] {
        if let minutes = med.afterWakeMinutes {
            if let woke = wakeTimes[day] { return [woke.addingTimeInterval(Double(minutes) * 60)] }
            return [at(minutes: med.afterWakeFallback, on: day, calendar: calendar)].compactMap { $0 }
        }
        return med.times.sorted().compactMap { at(minutes: $0, on: day, calendar: calendar) }
    }

    private static func at(minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// Отметка, относящаяся к этому приёму (в пределах минуты от назначенного времени).
    static func record(for dose: Dose, in records: [DoseRecord]) -> DoseRecord? {
        records.first { $0.medicationID == dose.medicationID && abs($0.scheduled.timeIntervalSince(dose.scheduled)) < 60 }
    }

    static func state(of dose: Dose, records: [DoseRecord], now: Date) -> DoseState {
        if let record = record(for: dose, in: records) {
            return record.status == .taken ? .taken(record.at) : .skipped
        }
        if now.timeIntervalSince(dose.scheduled) > missedAfter { return .missed }
        if dose.scheduled.timeIntervalSince(now) <= dueBefore { return .due }
        return .upcoming
    }

    /// Курс закончен и все его приёмы отмечены как принятые.
    static func courseCompleted(_ med: Medication, records: [DoseRecord], wakeTimes: [Date: Date] = [:], now: Date, calendar: Calendar = .current) -> Bool {
        guard let end = med.endDate,
              let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)),
              now >= after else { return false }
        let all = doses(for: med, from: med.startDate, to: after, wakeTimes: wakeTimes, calendar: calendar)
        guard !all.isEmpty else { return false }
        return all.allSatisfy { record(for: $0, in: records)?.status == .taken }
    }

    /// Последние 7 полных дней без единого пропуска (и хотя бы один приём в них).
    static func cleanWeek(_ med: Medication, records: [DoseRecord], wakeTimes: [Date: Date] = [:], now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -7, to: today), from >= calendar.startOfDay(for: med.startDate) else { return false }
        let week = doses(for: med, from: from, to: today, wakeTimes: wakeTimes, calendar: calendar)
        guard !week.isEmpty else { return false }
        return week.allSatisfy { record(for: $0, in: records)?.status == .taken }
    }

    /// Текст напоминания. Без разрешения название на экране блокировки не показывается.
    static func reminderBody(_ med: Medication, showName: Bool) -> String {
        guard showName else { return "Откройте приложение, чтобы посмотреть" }
        var parts = [med.name]
        if !med.dose.isEmpty { parts.append(med.dose) }
        if let hint = med.meal.hint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }
}
