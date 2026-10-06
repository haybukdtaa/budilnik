import Foundation

/// Направление, под которое человек использует приложение. Определяет шаблоны, чек-лист и утреннюю программу.
enum WakeModule: String, Codable, CaseIterable, Identifiable {
    case basic, sport, study, work, prayer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return "Просто будильник"
        case .sport: return "Спорт"
        case .study: return "Учёба"
        case .work: return "Работа"
        case .prayer: return "Утренний намаз"
        }
    }

    var icon: String {
        switch self {
        case .basic: return "alarm"
        case .sport: return "figure.run"
        case .study: return "book"
        case .work: return "briefcase"
        case .prayer: return "moon.stars"
        }
    }

    var subtitle: String {
        switch self {
        case .basic: return "Будильник с заданием и серией"
        case .sport: return "Шаги и зарядка после подъёма"
        case .study: return "Фокус-таймер на утро"
        case .work: return "Главная задача дня"
        case .prayer: return "Будильник по времени Фаджра"
        }
    }

    var defaultChecklist: [String] {
        switch self {
        case .basic: return ["Выпить стакан воды", "Заправить кровать"]
        case .sport: return ["Выпить стакан воды", "Зарядка 10 минут", "Контрастный душ"]
        case .study: return ["Выпить стакан воды", "Повторить вчерашнее", "План занятий на день"]
        case .work: return ["Выпить стакан воды", "Записать главную задачу", "Проверить расписание"]
        case .prayer: return ["Омовение", "Утренний намаз"]
        }
    }

    /// Выбор этого модуля говорит о религиозных взглядах: данные остаются на телефоне, пока человек сам не разрешит.
    var isSensitive: Bool { self == .prayer }
}
