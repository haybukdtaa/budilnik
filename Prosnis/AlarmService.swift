import ActivityKit
import AlarmKit
import Foundation
import SwiftUI

/// Данные, которые система хранит вместе с будильником. Пока пустые.
struct ProsnisAlarmData: AlarmMetadata {}

/// Обёртка над системным будильником AlarmKit (iOS 26+).
@MainActor
final class AlarmService: ObservableObject {
    @Published var status: String = "Готов к проверке"

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

    /// Ставит тестовый будильник через `seconds` секунд.
    func scheduleTest(after seconds: TimeInterval) async {
        guard await ensureAuthorization() else {
            status = "Нет разрешения на будильники. Включите его в Настройках iPhone."
            return
        }

        let stopButton = AlarmButton(
            text: "Выключить",
            textColor: .white,
            systemImageName: "stop.circle"
        )
        let alert = AlarmPresentation.Alert(title: "Просыпайтесь", stopButton: stopButton)
        let attributes = AlarmAttributes<ProsnisAlarmData>(
            presentation: AlarmPresentation(alert: alert),
            metadata: ProsnisAlarmData(),
            tintColor: .orange
        )

        let fireDate = Date().addingTimeInterval(seconds)
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes,
            sound: .default
        )

        do {
            _ = try await manager.schedule(id: UUID(), configuration: configuration)
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            status = "Будильник сработает в \(formatter.string(from: fireDate)). Заблокируйте телефон и ждите."
        } catch {
            status = "Не удалось поставить будильник: \(error.localizedDescription)"
        }
    }

    /// Отменяет все будильники этого приложения.
    func cancelAll() {
        do {
            let alarms = try manager.alarms
            for alarm in alarms {
                try manager.cancel(id: alarm.id)
            }
            status = "Отменено будильников: \(alarms.count)"
        } catch {
            status = "Не удалось отменить: \(error.localizedDescription)"
        }
    }
}
