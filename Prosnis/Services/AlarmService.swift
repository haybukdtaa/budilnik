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
    }

    private var registry: Registry
    private let registryFile = FileStore<Registry>("scheduled_alarms")
    /// Идущие перестановки: следующая для того же будильника ждёт окончания предыдущей.
    private var inFlight: [UUID: Task<String?, Never>] = [:]

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

    /// Стоял ли будильник в системе на это время. Если нет, пропуск не считается провалом.
    func wasScheduled(_ item: AlarmItem, ring: Date) -> Bool {
        let key = item.id.uuidString
        if registry.failed.contains(key) { return false }
        if item.needsDatedSchedule {
            return (registry.dates[key] ?? []).contains { abs($0.timeIntervalSince(ring)) < 60 }
        }
        return true
    }

    /// Ставит (или переставляет) системные будильники. Перестановки одного будильника идут по очереди.
    /// Возвращает текст ошибки или nil.
    func sync(_ item: AlarmItem, context: ScheduleContext) async -> String? {
        let previous = inFlight[item.id]
        let task = Task { () -> String? in
            _ = await previous?.value
            if Task.isCancelled { return nil }
            return await self.performSync(item, context: context)
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

    private func performSync(_ item: AlarmItem, context: ScheduleContext) async -> String? {
        cancelAll(for: item.id)
        let key = item.id.uuidString
        guard item.isEnabled else {
            markFailed(key, false)
            return nil
        }
        guard await ensureAuthorization() else {
            markFailed(key, true)
            return "Нет разрешения на будильники. Включите его в Настройках iPhone."
        }
        let sound = SoundLibrary.option(item.soundID).fileName

        if item.needsDatedSchedule {
            // Время меняется по дням или есть исключения: ставим будильники на конкретные даты.
            let now = Date()
            let dates = ScheduleCalculator.effectiveOccurrences(
                for: item, from: now,
                to: now.addingTimeInterval(Double(AlarmService.datedHorizonDays) * 86400),
                context: context
            )
            var failed = false
            for date in dates {
                let systemID = UUID()
                let configuration = AlarmManager.AlarmConfiguration.alarm(
                    schedule: .fixed(date),
                    attributes: attributes(title: item.displayTitle),
                    stopIntent: stopIntent(for: item, systemID: systemID),
                    sound: .named(sound)
                )
                do {
                    _ = try await manager.schedule(id: systemID, configuration: configuration)
                    // Записываем сразу: если параллельно начнётся отмена, она увидит этот будильник.
                    registry.ids[key, default: []].append(systemID)
                    registry.dates[key, default: []].append(date)
                    saveRegistry()
                } catch {
                    failed = true
                }
            }
            markFailed(key, false)
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
        do {
            _ = try await manager.schedule(id: UUID(), configuration: configuration)
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "Проверочный звонок в \(formatter.string(from: fireDate)). Заблокируйте телефон и ждите."
        } catch {
            return "Не удалось поставить проверку: \(error.localizedDescription)"
        }
    }
}
