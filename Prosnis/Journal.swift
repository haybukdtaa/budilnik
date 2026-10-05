import Foundation
import SwiftUI

enum Outcome: String, Codable {
    case success    // встал и прошёл обе проверки
    case failed     // проспал: списание
    case technical  // сбой приложения или телефона: без списания
}

enum DisputeState: String, Codable {
    case none
    case refunded   // первый спор в аккаунте возвращается сразу
    case pending    // последующие споры рассматриваются вручную
}

struct JournalEvent: Codable, Hashable {
    var date: Date
    var text: String
}

/// Одна запись журнала: что произошло в одно утро и почему списали (или нет).
struct JournalEntry: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var alarmTitle: String
    var timeText: String
    var stake: Int
    var outcome: Outcome
    var events: [JournalEvent]
    var dispute: DisputeState = .none
    /// Тренировка: деньги не списывались.
    var isTraining = true

    /// Сколько реально списано по этой записи.
    var charged: Int {
        guard outcome == .failed, dispute != .refunded, !isTraining else { return 0 }
        return stake
    }
}

struct MonthStats {
    var saved = 0       // ставки тех утр, когда человек встал
    var lost = 0        // фактически списано
    var successes = 0
    var total = 0
    var streak = 0      // подряд успешных утр до сегодняшнего дня
}

struct StakeHint {
    var text: String
    var suggested: Int?
}

enum StakeAdvisor {
    /// Подсказка по ставке на основе последних утр. nil, если данных мало.
    static func hint(entries: [JournalEntry], current: Int) -> StakeHint? {
        let recent = entries
            .filter { $0.outcome != .technical }
            .sorted { $0.date > $1.date }
            .prefix(7)
        guard recent.count >= 5 else { return nil }
        let fails = recent.filter { $0.outcome == .failed }.count

        if fails >= 3 {
            let raised = max(current + 100, Int((Double(current) * 1.5 / 50).rounded()) * 50)
            return StakeHint(
                text: "Вы проспали \(fails) из последних \(recent.count) раз. Возможно, ставка \(current) ₽ слишком мала. Попробуйте \(raised) ₽.",
                suggested: raised
            )
        }
        if fails == 0 {
            return StakeHint(
                text: "Последние \(recent.count) раз вы вставали вовремя. Ставка \(current) ₽ работает, менять её не нужно.",
                suggested: nil
            )
        }
        return nil
    }
}

/// Журнал утр: хранение на диске, статистика, споры.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("journal.json")
        if let data = try? Data(contentsOf: fileURL),
           let items = try? JSONDecoder().decode([JournalEntry].self, from: data) {
            entries = items.sorted { $0.date > $1.date }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ entry: JournalEntry) {
        entries.append(entry)
        entries.sort { $0.date > $1.date }
        save()
    }

    func monthStats(now: Date = Date()) -> MonthStats {
        let calendar = Calendar.current
        let month = entries.filter {
            $0.outcome != .technical && calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }
        var stats = MonthStats()
        stats.total = month.count
        stats.successes = month.filter { $0.outcome == .success }.count
        stats.saved = month.filter { $0.outcome == .success }.reduce(0) { $0 + $1.stake }
        stats.lost = month.reduce(0) { $0 + $1.charged }
        for entry in entries.filter({ $0.outcome != .technical }) {
            if entry.outcome == .success { stats.streak += 1 } else { break }
        }
        return stats
    }

    /// Оспаривание. Первый спор в аккаунте возвращается сразу, остальные идут на рассмотрение.
    func dispute(_ entry: JournalEntry) {
        guard entry.outcome == .failed, entry.dispute == .none,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let hadEarlier = entries.contains { $0.dispute != .none }
        entries[index].dispute = hadEarlier ? .pending : .refunded
        save()
    }

    /// Тестовые записи, чтобы посмотреть экраны, пока нет настоящих будильников с заданиями.
    func addDemoEntries() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let outcomes: [Outcome] = [.success, .success, .failed, .success, .success, .technical, .success, .failed]
        for (offset, outcome) in outcomes.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -(offset + 1), to: today),
                  let ring = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: day) else { continue }
            func at(_ minutes: Int, _ text: String) -> JournalEvent {
                JournalEvent(date: ring.addingTimeInterval(Double(minutes) * 60), text: text)
            }
            var events = [at(0, "Прозвенел будильник"), at(1, "Нажато «Выключить»")]
            switch outcome {
            case .success:
                events += [at(3, "Задание выполнено"), at(13, "Повторная проверка пройдена")]
            case .failed:
                events += [at(11, "Время на задание истекло")]
            case .technical:
                events = [at(0, "Телефон был выключен, списание отменено")]
            }
            add(JournalEntry(
                date: ring,
                alarmTitle: "Работа",
                timeText: "06:30",
                stake: 500,
                outcome: outcome,
                events: events
            ))
        }
    }
}
