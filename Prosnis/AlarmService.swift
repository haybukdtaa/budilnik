import ActivityKit
import AlarmKit
import Foundation
import SwiftUI

/// Данные, которые система хранит вместе с будильником. Пока пустые.
struct ProsnisAlarmData: AlarmMetadata {}

/// Обёртка над системным будильником AlarmKit (iOS 26+).
@MainActor
final class AlarmService {
    private let manager = AlarmManager.shared

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

    /// Ставит (или переставляет) системный будильник. Возвращает текст ошибки или nil.
    func sync(_ item: AlarmItem) async -> String? {
        try? manager.cancel(id: item.id)
        guard item.isEnabled else { return nil }
        guard await ensureAuthorization() else {
            return "Нет разрешения на будильники. Включите его в Настройках iPhone."
        }

        let time = Alarm.Schedule.Relative.Time(hour: item.hour, minute: item.minute)
        let recurrence: Alarm.Schedule.Relative.Recurrence = item.weekdays.isEmpty
            ? .never
            : .weekly(item.weekdays.sorted().map(Weekdays.locale))
        let schedule = Alarm.Schedule.relative(.init(time: time, repeats: recurrence))

        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes(title: item.displayTitle),
            sound: .named(SoundLibrary.option(item.soundID).fileName)
        )

        do {
            _ = try await manager.schedule(id: item.id, configuration: configuration)
            return nil
        } catch {
            return "Не удалось поставить будильник: \(error.localizedDescription)"
        }
    }

    func cancel(id: UUID) {
        try? manager.cancel(id: id)
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
