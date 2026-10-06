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
    /// Какие системные будильники поставлены на конкретные даты для каждого нашего будильника.
    private var registry: [String: [UUID]]
    private let registryFile = FileStore<[String: [UUID]]>("scheduled_ids")

    private init() {
        registry = registryFile.load() ?? [:]
    }

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
        for systemID in registry[id.uuidString] ?? [] {
            try? manager.cancel(id: systemID)
        }
        registry[id.uuidString] = nil
        registryFile.save(registry)
    }

    func cancel(id: UUID) {
        try? manager.cancel(id: id)
    }

    /// Ставит (или переставляет) системные будильники. Возвращает текст ошибки или nil.
    func sync(_ item: AlarmItem, context: ScheduleContext) async -> String? {
        cancelAll(for: item.id)
        guard item.isEnabled else { return nil }
        guard await ensureAuthorization() else {
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
            var ids: [UUID] = []
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
                    ids.append(systemID)
                } catch {
                    failed = true
                }
            }
            registry[item.id.uuidString] = ids
            registryFile.save(registry)
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
            return nil
        } catch {
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
