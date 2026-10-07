import Foundation

enum ChallengeGoal: String, Codable, CaseIterable, Identifiable {
    case noMisses   // ни одного проспанного утра
    case wakeBefore // вставать не позже заданного времени
    case routine    // каждое утро выполнять чек-лист
    case prayer     // вставать на Фаджр

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noMisses: return "Без единого провала"
        case .wakeBefore: return "Вставать до времени"
        case .routine: return "Утро с чек-листом"
        case .prayer: return "Фаджр без пропусков"
        }
    }

    var detail: String {
        switch self {
        case .noMisses: return "Каждый будильник с заданием должен закончиться подъёмом"
        case .wakeBefore: return "Утро засчитывается, если подъём не позже выбранного времени"
        case .routine: return "После подъёма отмечены все пункты чек-листа"
        case .prayer: return "Каждый будильник на Фаджр закончился подъёмом"
        }
    }
}

enum ChallengeStatus: String, Codable {
    case active, completed, failed, abandoned

    var title: String {
        switch self {
        case .active: return "Идёт"
        case .completed: return "Пройден"
        case .failed: return "Сорван"
        case .abandoned: return "Остановлен"
        }
    }
}

/// Личный челлендж. Срок любой: от недели до года или бессрочно.
struct Challenge: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var goal: ChallengeGoal
    /// Для «вставать до времени»: минуты от полуночи.
    var wakeBeforeMinutes: Int?
    /// nil = бессрочный: идёт, пока не сорван или не остановлен.
    var durationDays: Int?
    var startDate: Date
    var status: ChallengeStatus = .active
    var endedAt: Date?
    var updatedAt: Date? = Date()

    /// Сведения о намазе не покидают телефон без разрешения.
    var isPrivate: Bool { goal == .prayer }
}

struct ChallengeProgress: Equatable {
    var status: ChallengeStatus
    var endedAt: Date?
    var daysPassed: Int
    var successDays: Int
    /// Утро, на котором челлендж сорвался.
    var failedOn: Date?
}

enum ChallengeEvaluator {
    /// Подходит ли утро под условие челленджа.
    static func passes(_ entry: JournalEntry, challenge: Challenge, calendar: Calendar) -> Bool {
        guard entry.outcome == .success else { return false }
        switch challenge.goal {
        case .noMisses, .prayer:
            return true
        case .wakeBefore:
            guard let limit = challenge.wakeBeforeMinutes else { return true }
            let parts = calendar.dateComponents([.hour, .minute], from: entry.date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0) <= limit
        case .routine:
            return entry.routineComplete
        }
    }

    static func evaluate(_ challenge: Challenge, entries: [JournalEntry], now: Date, calendar: Calendar = .current) -> ChallengeProgress {
        let start = calendar.startOfDay(for: challenge.startDate)
        let today = calendar.startOfDay(for: now)
        let end = challenge.durationDays.flatMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let daysPassed = max(0, (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1)

        // Утра до момента создания челленджа (даже в тот же день) не учитываются.
        let relevant = entries
            .filter { $0.counts && $0.date >= challenge.startDate && (end == nil || $0.date < end!) }
            // Челлендж по Фаджру смотрит только утра с намазом, остальные — только обычные утра.
            // Так сведения о намазе не попадают в обычные челленджи, которые уходят на сервер.
            .filter { challenge.goal == .prayer ? $0.isPrayer == true : $0.isPrayer != true }
            .sorted { $0.date < $1.date }

        var successDays = Set<Date>()
        for entry in relevant {
            // Чек-лист отмечается после подъёма: сегодняшнее утро без отметок ещё не провал.
            if challenge.goal == .routine, entry.outcome == .success, entry.routineTotal == nil,
               calendar.isDate(entry.date, inSameDayAs: now) {
                continue
            }
            if passes(entry, challenge: challenge, calendar: calendar) {
                successDays.insert(calendar.startOfDay(for: entry.date))
            } else if challenge.status == .active || challenge.status == .failed {
                return ChallengeProgress(
                    status: .failed, endedAt: entry.date,
                    daysPassed: daysPassed, successDays: successDays.count, failedOn: entry.date
                )
            }
        }

        // Остановленный вручную челлендж остаётся остановленным.
        if challenge.status == .abandoned {
            return ChallengeProgress(
                status: .abandoned, endedAt: challenge.endedAt,
                daysPassed: daysPassed, successDays: successDays.count, failedOn: nil
            )
        }

        if let end, now >= end {
            let status: ChallengeStatus = successDays.isEmpty ? .failed : .completed
            return ChallengeProgress(
                status: status, endedAt: end,
                daysPassed: challenge.durationDays ?? daysPassed, successDays: successDays.count, failedOn: nil
            )
        }

        return ChallengeProgress(
            status: .active, endedAt: nil,
            daysPassed: daysPassed, successDays: successDays.count, failedOn: nil
        )
    }
}

/// Парный челлендж с другом. Данные приходят с сервера.
struct PairChallenge: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var partner: UserProfile
    var durationDays: Int
    var startDate: Date
    var myDays: Int
    var partnerDays: Int
    var status: ChallengeStatus
}
