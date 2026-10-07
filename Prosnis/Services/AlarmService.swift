import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Данные, которые система хранит вместе с будильником. Пока пустые.
struct ProsnisAlarmData: AlarmMetadata {}

/// Обёртка над системным будильником AlarmKit (iOS 26+).
@MainActor
final class AlarmService {
    static let shared = AlarmService()

    /// На сколько дней вперёд ставятся будильники с меняющимся временем (Фаджр, календарь РФ).
    static let datedHorizonDays = 10

    private let manager = AlarmManager.shared

    /// Что поставлено в систему для каждого нашего будильника (ключ — id будильника).
    private struct Registry: Codable {
        var ids: [String: [UUID]] = [:]
        /// Даты, на которые будильник с меняющимся временем действительно поставлен.
        var dates: [String: [Date]] = [:]
        /// Будильники, которые в последний раз поставить не удалось.
        var failed: Set<String> = []
        /// Не поставлены, потому что разрешение на будильники выключено.
        var denied: Set<String>? = []
        /// Проверочные звонки: их не трогает уборка «призраков», пока не прозвенят.
        var tests: [UUID: Date]? = [:]
        /// До какого момента поставлены будильники с меняющимся временем (при последней постановке).
        var horizonEnd: [String: Date]? = [:]
        /// Даты внутри этого промежутка, которые поставить не удалось (сбой системы).
        var failedDates: [String: [Date]]? = [:]
        /// Когда будильник с заданием должен звонить, по поясу на момент постановки. Не стирается при смене пояса:
        /// утро нельзя «потерять», переведя часы.
        var expected: [String: ExpectedRings]? = [:]
    }

    /// Ожидаемые звонки для конкретных настроек будильника (version — время последнего изменения).
    struct ExpectedRings: Codable {
        var version: Date
        var rings: [RingCandidate]
    }

    private var registry: Registry
    private let registryFile = FileStore<Registry>("scheduled_alarms")
    /// Идущие перестановки: следующая для того же будильника ждёт окончания предыдущей.
    private var inFlight: [UUID: Task<String?, Never>] = [:]
    /// Растёт при полном удалении данных: начатые до него перестановки прекращаются.
    private var generation = 0

    private init() {
        registry = registryFile.load() ?? Registry()
    }

    func reloadIfNeeded() {
        if let loaded = registryFile.load() { registry = loaded }
    }

    private func saveRegistry() { registryFile.save(registry) }

    var isAuthorized: Bool { manager.authorizationState == .authorized }

    func requestAuthorization() async -> Bool { await ensureAuthorization() }

    private func ensureAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await manager.requestAuthorization() == .authorized
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    private func attributes(title: String) -> AlarmAttributes<ProsnisAlarmData> {
        let stopButton = AlarmButton(
            text: "Выключить",
            textColor: .white,
            systemImageName: "stop.circle"
        )
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stopButton)
        return AlarmAttributes<ProsnisAlarmData>(
            presentation: AlarmPresentation(alert: alert),
            metadata: ProsnisAlarmData(),
            tintColor: .orange
        )
    }

    private func stopIntent(for item: AlarmItem, systemID: UUID) -> (any LiveActivityIntent)? {
        guard item.hasTask else { return nil }
        return WakeStopIntent(alarmID: item.id.uuidString, systemID: systemID.uuidString, isRecheck: false)
    }

    /// Снимает все системные будильники, относящиеся к нашему будильнику.
    func cancelAll(for id: UUID) {
        try? manager.cancel(id: id)
        let key = id.uuidString
        for systemID in registry.ids[key] ?? [] {
            try? manager.cancel(id: systemID)
        }
        registry.ids[key] = nil
        // Прошедшие даты храним 30 дней: по ним сверка понимает, что будильник действительно стоял.
        let now = Date()
        registry.dates[key] = (registry.dates[key] ?? []).filter { $0 <= now && now.timeIntervalSince($0) < 30 * 86400 }
        saveRegistry()
    }

    /// Снимает вообще все будильники приложения (при удалении данных).
    func cancelEverything() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        if let all = try? manager.alarms {
            for alarm in all { try? manager.cancel(id: alarm.id) }
        }
        for ids in registry.ids.values {
            for id in ids { try? manager.cancel(id: id) }
        }
        registry = Registry()
        registryFile.delete()
    }

    func cancel(id: UUID) {
        try? manager.cancel(id: id)
    }

    /// Останавливает звонок (будильник при этом может остаться в расписании).
    func stop(id: UUID) {
        try? manager.stop(id: id)
    }

    /// Удаляет будильник после всех идущих перестановок, чтобы ни одна из них не поставила его снова.
    func remove(_ id: UUID) async {
        let previous = inFlight[id]
        _ = await previous?.value
        cancelAll(for: id)
        registry.expected?[id.uuidString] = nil
        saveRegistry()
    }

    /// Запоминает, когда будильник с заданием должен звонить в ближайшие дни, по текущему поясу.
    /// Ожидания для тех же настроек объединяются со старыми: после смены пояса у утра два времени, а не одно.
    func recordExpected(_ item: AlarmItem, context: ScheduleContext, now: Date = Date()) {
        let key = item.id.uuidString
        var all = registry.expected ?? [:]
        guard item.isEnabled && item.hasTask else {
            guard all[key] != nil else { return }
            all[key] = nil
            registry.expected = all
            saveRegistry()
            return
        }
        let version = AlarmStore.changedAt(item)
        let fresh = MissedMornings.candidates(
            ScheduleCalculator.effectiveOccurrences(
                for: item, from: now,
                to: now.addingTimeInterval(Double(AlarmService.datedHorizonDays + 1) * 86400),
                context: context
            ),
            calendar: context.calendar
        )
        var old: [RingCandidate] = []
        if let stored = all[key], abs(stored.version.timeIntervalSince(version)) < 1 {
            old = stored.rings.filter { now.timeIntervalSince($0.at) < 30 * 86400 }
        }
        all[key] = ExpectedRings(version: version, rings: MissedMornings.merged(old, fresh))
        registry.expected = all
        saveRegistry()
    }

    /// Ожидаемые звонки для текущих настроек будильника (после изменения настроек старые не действуют).
    func expectedRings(for item: AlarmItem) -> [RingCandidate] {
        guard let stored = registry.expected?[item.id.uuidString],
              abs(stored.version.timeIntervalSince(AlarmStore.changedAt(item))) < 1 else { return [] }
        return stored.rings
    }

    /// Самый ранний конец поставленного промежутка среди будильников с меняющимся временем.
    func earliestHorizonEnd(for ids: [UUID]) -> Date? {
        ids.compactMap { registry.horizonEnd?[$0.uuidString] }.min()
    }

    func isFailed(_ id: UUID) -> Bool { registry.failed.contains(id.uuidString) }

    /// Будильник, который ставится прямо сейчас: уборка «призраков» не трогает его час.
    private func protect(_ id: UUID) {
        var tests = registry.tests ?? [:]
        tests[id] = Date()
        registry.tests = tests
        saveRegistry()
    }

    /// Снимает системные будильники, которых нет ни у одного нашего будильника («призраки» после сбоев).
    func pruneOrphans(known: Set<UUID>) {
        guard let all = try? manager.alarms else { return }
        let now = Date()
        var tests = registry.tests ?? [:]
        tests = tests.filter { now.timeIntervalSince($0.value) < 3600 }
        registry.tests = tests
        let registered = Set(registry.ids.values.flatMap { $0 })
        for alarm in all where !known.contains(alarm.id) && !registered.contains(alarm.id) && tests[alarm.id] == nil {
            try? manager.cancel(id: alarm.id)
        }
        saveRegistry()
    }

    enum ScheduleState: Equatable {
        case scheduled
        /// Разрешение на будильники выключил сам человек.
        case permissionMissing
        /// Будильник с меняющимся временем не поставлен, потому что приложение не открывали дольше 10 дней.
        /// Об этом предупреждают условия ставки и напоминание: это ответственность человека.
        case notRefreshed
        /// Сбой системы или приложения: человек не виноват.
        case systemFailure
    }

    /// Чистая функция: был ли будильник в системе на время звонка и кто отвечает, если нет.
    nonisolated static func classify(
        authorized: Bool, denied: Bool, failed: Bool, dated: Bool, scheduledDates: [Date],
        failedDates: [Date] = [], horizonEnd: Date? = nil, ring: Date
    ) -> ScheduleState {
        if !authorized || denied { return .permissionMissing }
        if dated {
            if scheduledDates.contains(where: { abs($0.timeIntervalSince(ring)) < 60 }) { return .scheduled }
            if failedDates.contains(where: { abs($0.timeIntervalSince(ring)) < 60 }) { return .systemFailure }
            // Звонок позже конца поставленного промежутка: новые даты не поставлены, потому что приложение не открывали.
            if let end = horizonEnd ?? scheduledDates.max(), ring > end.addingTimeInterval(60) { return .notRefreshed }
            return .systemFailure
        }
        return failed ? .systemFailure : .scheduled
    }

    /// Стоял ли будильник в системе на это время.
    func scheduleState(_ item: AlarmItem, ring: Date) -> ScheduleState {
        let key = item.id.uuidString
        return AlarmService.classify(
            authorized: isAuthorized,
            denied: (registry.denied ?? []).contains(key),
            failed: registry.failed.contains(key),
            dated: item.needsDatedSchedule,
            scheduledDates: registry.dates[key] ?? [],
            failedDates: registry.failedDates?[key] ?? [],
            horizonEnd: registry.horizonEnd?[key],
            ring: ring
        )
    }

    private func markDenied(_ key: String, _ denied: Bool) {
        var set = registry.denied ?? []
        if denied { set.insert(key) } else { set.remove(key) }
        registry.denied = set
        saveRegistry()
    }

    /// Ставит (или переставляет) системные будильники. Перестановки одного будильника идут по очереди.
    /// Возвращает текст ошибки или nil.
    func sync(_ item: AlarmItem, context: ScheduleContext) async -> String? {
        let previous = inFlight[item.id]
        let startedGeneration = generation
        let task = Task { () -> String? in
            _ = await previous?.value
            if Task.isCancelled || startedGeneration != self.generation { return nil }
            return await self.performSync(item, context: context, generation: startedGeneration)
        }
        inFlight[item.id] = task
        let result = await task.value
        if inFlight[item.id] == task { inFlight[item.id] = nil }
        return result
    }

    private func markFailed(_ key: String, _ failed: Bool) {
        if failed { registry.failed.insert(key) } else { registry.failed.remove(key) }
        saveRegistry()
    }

    /// Будильник ещё нужен: не удалён, не выключен, данные не стёрты.
    private func stillWanted(_ item: AlarmItem, generation: Int) -> Bool {
        generation == self.generation
            && !Task.isCancelled
            && AlarmStore.shared.alarms.contains { $0.id == item.id && $0.isEnabled }
    }

    private func performSync(_ item: AlarmItem, context: ScheduleContext, generation: Int) async -> String? {
        cancelAll(for: item.id)
        let key = item.id.uuidString
        guard item.isEnabled else {
            markFailed(key, false)
            return nil
        }
        guard await ensureAuthorization() else {
            markFailed(key, true)
            markDenied(key, true)
            return "Нет разрешения на будильники. Включите его в Настройках iPhone."
        }
        markDenied(key, false)
        guard stillWanted(item, generation: generation) else { return nil }
        let sound = SoundLibrary.option(item.soundID).fileName

        if item.needsDatedSchedule {
            // Время меняется по дням или есть исключения: ставим будильники на конкретные даты.
            let now = Date()
            let horizon = now.addingTimeInterval(Double(AlarmService.datedHorizonDays) * 86400)
            let dates = ScheduleCalculator.effectiveOccurrences(for: item, from: now, to: horizon, context: context)
            // Конец промежутка записываем до постановки: звонок внутри него, который не встал, — сбой, а не «не открывали».
            var ends = registry.horizonEnd ?? [:]
            ends[key] = horizon
            registry.horizonEnd = ends
            var failedList = (registry.failedDates?[key] ?? []).filter { $0 <= now && now.timeIntervalSince($0) < 30 * 86400 }
            var failed = false
            for date in dates {
                guard stillWanted(item, generation: generation) else { break }
                let systemID = UUID()
                let configuration = AlarmManager.AlarmConfiguration.alarm(
                    schedule: .fixed(date),
                    attributes: attributes(title: item.displayTitle),
                    stopIntent: stopIntent(for: item, systemID: systemID),
                    sound: .named(sound)
                )
                do {
                    _ = try await manager.schedule(id: systemID, configuration: configuration)
                    guard stillWanted(item, generation: generation) else {
                        // Пока ставили, будильник удалили или выключили: снимаем то, что успели поставить.
                        try? manager.cancel(id: systemID)
                        break
                    }
                    // Записываем сразу: если параллельно начнётся отмена, она увидит этот будильник.
                    registry.ids[key, default: []].append(systemID)
                    registry.dates[key, default: []].append(date)
                    saveRegistry()
                } catch {
                    failed = true
                    failedList.append(date)
                }
            }
            var allFailed = registry.failedDates ?? [:]
            allFailed[key] = failedList
            registry.failedDates = allFailed
            // Частичный сбой отмечается: при следующем открытии будильник переставится.
            markFailed(key, failed)
            if item.isFajr && dates.isEmpty {
                return "В ближайшие дни время Фаджра не определяется для выбранного города. Проверьте настройки намаза."
            }
            return failed ? "Часть будильников поставить не удалось. Попробуйте ещё раз." : nil
        }

        let time = Alarm.Schedule.Relative.Time(hour: item.hour, minute: item.minute)
        let recurrence: Alarm.Schedule.Relative.Recurrence = item.weekdays.isEmpty
            ? .never
            : .weekly(item.weekdays.sorted().map(Weekdays.locale))
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .relative(.init(time: time, repeats: recurrence)),
            attributes: attributes(title: item.displayTitle),
            stopIntent: stopIntent(for: item, systemID: item.id),
            sound: .named(sound)
        )
        do {
            _ = try await manager.schedule(id: item.id, configuration: configuration)
            guard stillWanted(item, generation: generation) else {
                try? manager.cancel(id: item.id)
                return nil
            }
            markFailed(key, false)
            return nil
        } catch {
            markFailed(key, true)
            return "Не удалось поставить будильник: \(error.localizedDescription)"
        }
    }

    /// Повторный звонок проверки. Возвращает идентификатор системного будильника или nil при сбое.
    func scheduleRecheck(alarmID: UUID, soundID: String, at date: Date) async -> UUID? {
        guard await ensureAuthorization() else { return nil }
        let systemID = UUID()
        protect(systemID)
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(date),
            attributes: attributes(title: "Проверка: вы не спите?"),
            stopIntent: WakeStopIntent(alarmID: alarmID.uuidString, systemID: systemID.uuidString, isRecheck: true),
            sound: .named(SoundLibrary.option(soundID).fileName)
        )
        do {
            _ = try await manager.schedule(id: systemID, configuration: configuration)
            return systemID
        } catch {
            return nil
        }
    }

    /// Тестовый будильник через `seconds` секунд, чтобы проверить звонок.
    func scheduleTest(after seconds: TimeInterval) async -> String {
        guard await ensureAuthorization() else {
            return "Нет разрешения на будильники. Включите его в Настройках iPhone."
        }
        let fireDate = Date().addingTimeInterval(seconds)
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes(title: "Проверка"),
            sound: .default
        )
        let testID = UUID()
        protect(testID)
        do {
            _ = try await manager.schedule(id: testID, configuration: configuration)
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "Проверочный звонок в \(formatter.string(from: fireDate)). Заблокируйте телефон и ждите."
        } catch {
            return "Не удалось поставить проверку: \(error.localizedDescription)"
        }
    }
}
