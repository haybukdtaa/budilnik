import Foundation

struct Badge: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    /// Значок про намаз: виден только владельцу, пока он сам не разрешит показывать.
    let isPrivate: Bool
}

struct UnlockedBadge: Identifiable, Hashable {
    let badge: Badge
    let date: Date
    var id: String { badge.id }
}

struct WeekSummary: Equatable {
    var start: Date
    var mornings = 0
    var successes = 0
    var xp = 0
    /// Средняя минута подъёма от полуночи по успешным утрам.
    var averageWakeMinutes: Int?

    var regularity: Double { mornings == 0 ? 0 : Double(successes) / Double(mornings) }
}

struct ProgressSnapshot: Equatable {
    var xp = 0
    var level = 1
    var levelProgress = 0.0
    var xpForNextLevel = 100
    var currentStreak = 0
    var longestStreak = 0
    var totalWakes = 0
    var unlocked: [UnlockedBadge] = []
    var tree = TreeState(stage: 0, wilt: 0)
    /// Выросшие деревья в саду.
    var garden: [CompletedTree] = []
    var title: String { Titles.title(forLevel: level) }
    var thisWeek: WeekSummary
    var lastWeek: WeekSummary
}

/// Опыт, уровни, значки, дерево и итоги недели. Чистая функция от журнала и челленджей,
/// поэтому сервер сможет пересчитать то же самое и проверить честность.
enum ProgressEngine {
    static let badges: [Badge] = [
        Badge(id: "first_wake", title: "Первое утро", detail: "Первый подъём с заданием", icon: "sunrise.fill", isPrivate: false),
        Badge(id: "streak_3", title: "Серия 3", detail: "3 подъёма подряд", icon: "flame", isPrivate: false),
        Badge(id: "streak_7", title: "Серия 7", detail: "Неделя без провалов", icon: "flame.fill", isPrivate: false),
        Badge(id: "streak_14", title: "Серия 14", detail: "Две недели подряд", icon: "flame.circle", isPrivate: false),
        Badge(id: "streak_30", title: "Серия 30", detail: "Месяц подряд", icon: "flame.circle.fill", isPrivate: false),
        Badge(id: "streak_60", title: "Серия 60", detail: "Два месяца подряд", icon: "bolt.heart", isPrivate: false),
        Badge(id: "streak_100", title: "Серия 100", detail: "Сто утр подряд", icon: "crown", isPrivate: false),
        Badge(id: "streak_365", title: "Серия 365", detail: "Год без провалов", icon: "crown.fill", isPrivate: false),
        Badge(id: "wakes_10", title: "10 утр", detail: "10 подъёмов всего", icon: "10.circle", isPrivate: false),
        Badge(id: "wakes_50", title: "50 утр", detail: "50 подъёмов всего", icon: "50.circle", isPrivate: false),
        Badge(id: "wakes_100", title: "100 утр", detail: "100 подъёмов всего", icon: "100.circle", isPrivate: false),
        Badge(id: "wakes_500", title: "500 утр", detail: "500 подъёмов всего", icon: "star.circle.fill", isPrivate: false),
        Badge(id: "early_bird", title: "Ранняя пташка", detail: "10 подъёмов до 6:00", icon: "bird", isPrivate: false),
        Badge(id: "all_tasks", title: "Мастер заданий", detail: "Встали с каждым видом задания", icon: "square.stack.3d.up", isPrivate: false),
        Badge(id: "perfect_week", title: "Идеальная неделя", detail: "5+ подъёмов за неделю без провалов", icon: "calendar.badge.checkmark", isPrivate: false),
        Badge(id: "routine_10", title: "Режим", detail: "10 утр с полным чек-листом", icon: "checklist", isPrivate: false),
        Badge(id: "challenge_first", title: "Первый челлендж", detail: "Пройден первый челлендж", icon: "flag.checkered", isPrivate: false),
        Badge(id: "fajr_7", title: "Неделя Фаджра", detail: "7 подъёмов на Фаджр", icon: "moon.stars.fill", isPrivate: true),
    ]

    static func badge(_ id: String) -> Badge? { badges.first { $0.id == id } }

    /// Опыт, нужный для достижения уровня: 1 → 0, 2 → 100, 3 → 300, 4 → 600 ...
    static func threshold(forLevel level: Int) -> Int { 50 * level * (level - 1) }

    static func level(forXP xp: Int) -> (level: Int, progress: Double, toNext: Int) {
        var level = 1
        while threshold(forLevel: level + 1) <= xp { level += 1 }
        let low = threshold(forLevel: level)
        let high = threshold(forLevel: level + 1)
        let progress = Double(xp - low) / Double(high - low)
        return (level, progress, high - xp)
    }

    static func xp(forSuccessWithStreak streak: Int) -> Int { 10 + min(streak, 10) }

    static func compute(
        entries: [JournalEntry],
        challenges: [Challenge],
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> ProgressSnapshot {
        var calendar = inputCalendar
        calendar.firstWeekday = 2 // неделя с понедельника
        calendar.minimumDaysInFirstWeek = 4

        let ordered = entries.filter(\.counts).sorted { $0.date < $1.date }

        var totalXP = 0
        var streak = 0
        var longest = 0
        var wakes = 0
        var earlyWakes = 0
        var fajrWakes = 0
        var fullRoutines = 0
        var taskKinds = Set<TaskKind>()
        var unlocked: [String: Date] = [:]
        var xpByEntry: [UUID: Int] = [:]

        func unlock(_ id: String, _ date: Date) {
            if unlocked[id] == nil { unlocked[id] = date }
        }

        // Серия и число подъёмов считаются по утрам (дням), а не по будильникам:
        // день удачный, если все будильники с заданием в этот день закончились подъёмом.
        let byDay = Dictionary(grouping: ordered) { calendar.startOfDay(for: $0.date) }
        var dayResults: [Bool] = []
        var garden: [CompletedTree] = []
        for day in byDay.keys.sorted() {
            let dayEntries = (byDay[day] ?? []).sorted { $0.date < $1.date }
            let daySuccess = dayEntries.allSatisfy { $0.outcome == .success }
            dayResults.append(daySuccess)
            if daySuccess {
                streak += 1
                wakes += 1
                longest = max(longest, streak)
            } else {
                streak = 0
            }

            for entry in dayEntries where entry.outcome == .success {
                var gained = ProgressEngine.xp(forSuccessWithStreak: daySuccess ? streak : 0)
                if entry.routineComplete && (entry.routineTotal ?? 0) > 0 { fullRoutines += 1 }
                gained += 2 * (entry.routineDone?.count ?? 0)
                totalXP += gained
                xpByEntry[entry.id] = gained

                // Утра с намазом в публичный значок не идут: он выдавал бы религиозную практику.
                if entry.isPrayer != true && calendar.component(.hour, from: entry.date) < 6 { earlyWakes += 1 }
                if entry.isPrayer == true { fajrWakes += 1 }
                if let kind = entry.taskKind { taskKinds.insert(kind) }

                if earlyWakes >= 10 { unlock("early_bird", entry.date) }
                if fajrWakes >= 7 { unlock("fajr_7", entry.date) }
                if fullRoutines >= 10 { unlock("routine_10", entry.date) }
                if taskKinds.count == TaskKind.allCases.count { unlock("all_tasks", entry.date) }
            }

            if daySuccess, let last = dayEntries.last {
                // Каждые 100 удачных утр дерево вырастает и переезжает в сад.
                if wakes % TreeState.cycle == 0 {
                    garden.append(CompletedTree(index: wakes / TreeState.cycle - 1, date: last.date))
                }
                unlock("first_wake", last.date)
                for n in [3, 7, 14, 30, 60, 100, 365] where streak >= n { unlock("streak_\(n)", last.date) }
                for n in [10, 50, 100, 500] where wakes >= n { unlock("wakes_\(n)", last.date) }
            }
        }

        // Идеальная неделя: 5 и больше подъёмов, ни одного провала.
        let byWeek = Dictionary(grouping: ordered) { calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        for (_, week) in byWeek.sorted(by: { $0.key < $1.key }) {
            let successes = week.filter { $0.outcome == .success }
            if successes.count >= 5, !week.contains(where: { $0.outcome == .failed }), let last = week.last {
                unlock("perfect_week", last.date)
            }
        }

        let completed = challenges.filter { $0.status == .completed }.sorted { ($0.endedAt ?? $0.startDate) < ($1.endedAt ?? $1.startDate) }
        for challenge in completed {
            totalXP += 50 + (challenge.durationDays ?? 0)
        }
        if let first = completed.first {
            unlock("challenge_first", first.endedAt ?? first.startDate)
        }

        let levelInfo = level(forXP: totalXP)

        // Дерево: растёт с подъёмами, вянет от недавних провалов, цветёт и плодоносит от серии.
        let progress = wakes % TreeState.cycle
        let recentFailures = dayResults.suffix(7).filter { !$0 }.count
        let wilt = min(recentFailures, 3)
        let tree = TreeState(
            index: wakes / TreeState.cycle,
            progress: progress,
            stage: TreeState.stage(forProgress: progress),
            wilt: wilt,
            flowers: wilt == 0 && streak >= TreeState.flowersStreak,
            fruits: wilt == 0 && streak >= TreeState.fruitsStreak
        )

        func summary(weekContaining date: Date) -> WeekSummary {
            let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            let start = interval?.start ?? calendar.startOfDay(for: date)
            let end = interval?.end ?? start.addingTimeInterval(7 * 86400)
            let week = ordered.filter { $0.date >= start && $0.date < end }
            let successes = week.filter { $0.outcome == .success }
            let minutes = successes.map { calendar.component(.hour, from: $0.date) * 60 + calendar.component(.minute, from: $0.date) }
            return WeekSummary(
                start: start,
                mornings: week.count,
                successes: successes.count,
                xp: successes.reduce(0) { $0 + (xpByEntry[$1.id] ?? 0) },
                averageWakeMinutes: minutes.isEmpty ? nil : minutes.reduce(0, +) / minutes.count
            )
        }
        let lastWeekDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let unlockedList = unlocked.compactMap { id, date in badge(id).map { UnlockedBadge(badge: $0, date: date) } }
            .sorted { $0.date < $1.date }

        return ProgressSnapshot(
            xp: totalXP,
            level: levelInfo.level,
            levelProgress: levelInfo.progress,
            xpForNextLevel: levelInfo.toNext,
            currentStreak: streak,
            longestStreak: longest,
            totalWakes: wakes,
            unlocked: unlockedList,
            tree: tree,
            garden: garden,
            thisWeek: summary(weekContaining: now),
            lastWeek: summary(weekContaining: lastWeekDate)
        )
    }
}
