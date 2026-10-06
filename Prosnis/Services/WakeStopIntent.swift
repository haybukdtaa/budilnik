import AlarmKit
import AppIntents
import Foundation

/// Срабатывает, когда на звонке нажали «Выключить». Останавливает звонок и открывает приложение с заданием.
struct WakeStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Открыть задание"
    static var openAppWhenRun: Bool = true

    /// Наш будильник.
    @Parameter(title: "Будильник")
    var alarmID: String

    /// Системный будильник, который сейчас звонит.
    @Parameter(title: "Звонок")
    var systemID: String

    @Parameter(title: "Повторная проверка")
    var isRecheck: Bool

    init() {
        alarmID = ""
        systemID = ""
        isRecheck = false
    }

    init(alarmID: String, systemID: String, isRecheck: Bool) {
        self.alarmID = alarmID
        self.systemID = systemID
        self.isRecheck = isRecheck
    }

    func perform() async throws -> some IntentResult {
        if let ringing = UUID(uuidString: systemID) {
            try? AlarmManager.shared.stop(id: ringing)
        }
        let id = UUID(uuidString: alarmID)
        let recheck = isRecheck
        await MainActor.run {
            WakeCoordinator.shared.handleStop(alarmID: id, isRecheck: recheck)
        }
        return .result()
    }
}
