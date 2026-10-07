import Foundation
import SwiftUI

enum Outcome: String, Codable {
    case success    // встал и прошёл обе проверки
    case failed     // проспал: списание
    case technical  // сбой приложения или телефона: без списания
}

enum DisputeState: String, Codable {
    case none
    case pending    // спор отправлен и рассматривается по журналу и событиям утра
    case refunded   // спор решён в пользу человека, деньги возвращены
    case rejected   // спор рассмотрен, списание остаётся
}

struct JournalEvent: Codable, Hashable {
    var date: Date
    var text: String
}

/// Одна запись журнала: что произошло в одно утро и почему списали (или нет).
struct JournalEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Время первого звонка этого утра.
    var date: Date
    /// Какой будильник. nil у тестовых записей и у быстрой проверки.
    var alarmID: UUID?
    /// Только у записей старых версий: тогда первый пропуск прощался. Сейчас прощений нет.
    var forgiven: Bool?
    var alarmTitle: String
    var timeText: String
    var stake: Int
    var outcome: Outcome
    var events: [JournalEvent]
    var dispute: DisputeState = .none
    /// Тренировка: деньги не списывались.
    var isTraining = true
    /// Тестовая запись для просмотра экранов. Не участвует в статистике, серии и челленджах.
    var isDemo: Bool?
    var module: WakeModule?
    /// Утро, связанное с намазом. Не покидает телефон без разрешения.
    var isPrayer: Bool?
    var taskKind: TaskKind?
    /// Что из утреннего чек-листа отмечено и сколько пунктов было всего.
    var routineDone: [String]?
    var routineTotal: Int?
    /// Ссылка на платёжную операцию по ставке этого утра.
    var paymentRef: UUID?

    /// Сколько реально списано по этой записи.
    var charged: Int {
        guard outcome == .failed, dispute != .refunded, !isTraining else { return 0 }
        return stake
    }

    var counts: Bool { isDemo != true && outcome != .technical }
    /// Чек-лист выполнен. Пустой чек-лист (все пункты удалены) считается выполненным.
    var routineComplete: Bool {
        guard let total = routineTotal else { return false }
        return (routineDone?.count ?? 0) >= total
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
            .filter(\.counts)
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
    static let shared = JournalStore()

    @Published private(set) var entries: [JournalEntry] = []

    // Файл зашифрован и доступен после первой разблокировки телефона: будильник может записать итог утра,
    // даже если приложение запустилось из звонка.
    private let file = FileStore<[JournalEntry]>("journal")
    /// Файл не прочитался при запуске: перед сохранением нужно слить его с тем, что в памяти.
    private var needsMerge = false

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        entries = (result.value ?? []).sorted { $0.date > $1.date }
        needsMerge = result.state == .unreadable
    }

    /// Если при запуске журнал был закрыт (телефон не разблокирован), перечитывает и сливает его.
    func reloadIfNeeded() {
        guard needsMerge else { return }
        let result = file.loadWithState()
        guard result.state != .unreadable else { return }
        let known = Set(entries.map(\.id))
        entries += (result.value ?? []).filter { !known.contains($0.id) }
        entries.sort { $0.date > $1.date }
        needsMerge = false
        if result.state == .loaded { file.save(entries) }
    }

    private func save() {
        if needsMerge {
            let result = file.loadWithState()
            switch result.state {
            case .loaded:
                let known = Set(entries.map(\.id))
                entries += (result.value ?? []).filter { !known.contains($0.id) }
                entries.sort { $0.date > $1.date }
                needsMerge = false
            case .missing, .corrupt:
                needsMerge = false
            case .unreadable:
                return // файл всё ещё закрыт: сохраним позже, ничего не теряя
            }
        }
        file.save(entries)
    }

    /// Записи, которые идут в статистику (без тестовых).
    var realEntries: [JournalEntry] { entries.filter { $0.isDemo != true } }

    func add(_ entry: JournalEntry) {
        entries.append(entry)
        entries.sort { $0.date > $1.date }
        save()
        AppEvents.journalChanged(entry, isNew: true)
    }

    func setRoutine(entryID: UUID, done: [String], total: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].routineDone = done
        entries[index].routineTotal = total
        save()
        AppEvents.journalChanged(entries[index])
    }

    /// Есть ли запись об этом будильнике около указанного звонка.
    func hasEntry(alarmID: UUID, near ring: Date) -> Bool {
        entries.contains { $0.alarmID == alarmID && abs($0.date.timeIntervalSince(ring)) < 3600 }
    }

    func monthStats(now: Date = Date()) -> MonthStats {
        let calendar = Calendar.current
        let counted = entries.filter(\.counts)
        let month = counted.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
        var stats = MonthStats()
        stats.total = month.count
        stats.successes = month.filter { $0.outcome == .success }.count
        stats.saved = month.filter { $0.outcome == .success }.reduce(0) { $0 + $1.stake }
        stats.lost = month.reduce(0) { $0 + $1.charged }
        // Серия считается так же, как во вкладке «Прогресс»: по утрам, а не по будильникам.
        stats.streak = ProgressEngine.compute(entries: counted, challenges: [], now: now).currentStreak
        return stats
    }

    /// Оспаривание. Автоматического возврата нет: каждый спор рассматривается по записям журнала и событиям утра.
    func dispute(_ entry: JournalEntry) {
        guard entry.outcome == .failed, entry.dispute == .none, entry.stake > 0,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].dispute = .pending
        save()
        AppEvents.journalChanged(entries[index])
    }

    /// Итог рассмотрения спора (придёт с сервера). При решении в пользу человека деньги возвращаются.
    func resolveDispute(entryID: UUID, refund: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }), entries[index].dispute == .pending else { return }
        entries[index].dispute = refund ? .refunded : .rejected
        save()
        let entry = entries[index]
        if refund, let ref = entry.paymentRef, entry.stake > 0 {
            PaymentsStore.shared.refund(reference: ref, amount: entry.stake)
        }
        AppEvents.journalChanged(entry)
    }

    /// Тестовые записи, чтобы посмотреть экраны. В статистику не идут.
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
            entries.append(JournalEntry(
                date: ring,
                alarmTitle: "Тест",
                timeText: "06:30",
                stake: 500,
                outcome: outcome,
                events: events,
                isDemo: true
            ))
        }
        entries.sort { $0.date > $1.date }
        save()
    }

    func removeDemoEntries() {
        entries.removeAll { $0.isDemo == true }
        save()
    }
}
