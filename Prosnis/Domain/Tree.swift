import Foundation

/// Вид дерева. Выбирается для каждого нового дерева и не меняется, пока оно не вырастет.
enum TreeSpecies: String, Codable, CaseIterable, Identifiable {
    case oak, sakura, pine, birch, maple, palm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oak: return "Дуб"
        case .sakura: return "Сакура"
        case .pine: return "Сосна"
        case .birch: return "Берёза"
        case .maple: return "Клён"
        case .palm: return "Пальма"
        }
    }

    var detail: String {
        switch self {
        case .oak: return "Крепкий и раскидистый"
        case .sakura: return "Цветёт розовым"
        case .pine: return "Вечнозелёная, растёт ярусами"
        case .birch: return "Белый ствол, светлая крона"
        case .maple: return "Яркая красно-оранжевая листва"
        case .palm: return "Высокая, с широкими листьями"
        }
    }
}

/// Текущее дерево: растёт от подъёмов, вянет от провалов, цветёт и плодоносит от серии.
struct TreeState: Equatable {
    /// Номер дерева (0 — первое). Выросшие раньше стоят в саду.
    var index: Int = 0
    /// Удачных утр у этого дерева (0...cycle).
    var progress: Int = 0
    /// 0 = семечко ... 7 = вековое дерево.
    var stage: Int
    /// 0 = здоровое ... 3 = сильно увяло (недавние провалы).
    var wilt: Int
    /// Цветы: неделя подряд без провалов.
    var flowers = false
    /// Плоды: месяц подряд без провалов.
    var fruits = false

    /// Сколько удачных утр нужно, чтобы дерево выросло и переехало в сад.
    static let cycle = 100
    static let flowersStreak = 7
    static let fruitsStreak = 30

    static let stageTitles = [
        "Семечко", "Росток", "Саженец", "Молодое деревце",
        "Деревце", "Крепкое дерево", "Большое дерево", "Вековое дерево",
    ]
    /// Сколько удачных утр нужно для каждой стадии внутри одного дерева.
    static let thresholds = [0, 1, 3, 7, 14, 30, 60, 85]

    var title: String { TreeState.stageTitles[min(max(stage, 0), 7)] }

    /// Сколько утр до следующей стадии или до переезда в сад.
    var wakesToNext: Int {
        let next = stage + 1 < TreeState.thresholds.count ? TreeState.thresholds[stage + 1] : TreeState.cycle
        return max(0, next - progress)
    }

    var isLastStage: Bool { stage + 1 >= TreeState.thresholds.count }

    static func stage(forProgress progress: Int) -> Int {
        max(0, thresholds.lastIndex { progress >= $0 } ?? 0)
    }
}

/// Дерево, которое выросло и стоит в саду навсегда.
struct CompletedTree: Equatable, Identifiable {
    let index: Int
    /// Утро, на котором дерево выросло (сотое удачное утро этого дерева).
    let date: Date

    var id: Int { index }
}

/// Звания по уровню: человек начинает думать о себе как о том, кто встаёт.
enum Titles {
    static let names = [
        "Новичок", "Пробуждённый", "Утренний", "Жаворонок", "Хозяин утра",
        "Хранитель рассвета", "Мастер подъёма", "Повелитель утра", "Легенда рассвета",
    ]

    static func title(forLevel level: Int) -> String {
        names[min(max(level, 1), names.count) - 1]
    }

    /// Уровень, с которого начинается следующее звание (nil — звание высшее).
    static func nextTitleLevel(after level: Int) -> Int? {
        level < names.count ? level + 1 : nil
    }
}

/// Когда сообщать друзьям-свидетелям о проспанном утре. Никаких сумм и времени в сообщении нет.
enum WitnessPolicy {
    /// Сообщение о прошлом утре старше суток уже не нужно (например, после недели без открытия приложения).
    static let freshness: TimeInterval = 24 * 3600

    static func shouldNotify(
        entry: JournalEntry,
        privacy: PrivacySettings,
        witnesses: [UUID],
        now: Date,
        lastNotifiedDay: String?,
        calendar: Calendar = .current
    ) -> Bool {
        guard !witnesses.isEmpty, entry.counts, entry.outcome == .failed else { return false }
        // Проспанный Фаджр без согласия не выдаём даже свидетелям.
        if entry.isPrayer == true && !privacy.sharePrayer { return false }
        guard now.timeIntervalSince(entry.date) < freshness else { return false }
        // Одно сообщение за утро, даже если проспано несколько будильников.
        return dayKey(entry.date, calendar: calendar) != lastNotifiedDay
    }

    /// День как «гггг-мм-дд» по часам владельца: у свидетеля в другом поясе дата не сдвинется.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension Titles {
    /// Сменилось ли звание (после 9-го уровня оно уже не меняется).
    static func changed(fromLevel old: Int, toLevel new: Int) -> Bool {
        title(forLevel: old) != title(forLevel: new)
    }
}
