import AlarmKit
import AppIntents
import Foundation

/// Срабатывает, когда на звонке нажали «Выключить». Открывает приложение с заданием.
struct WakeStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Открыть задание"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Будильник")
    var alarmID: String

    @Parameter(title: "Повторная проверка")
    var isRecheck: Bool

    init() {
        alarmID = ""
        isRecheck = false
    }

    init(alarmID: String, isRecheck: Bool) {
        self.alarmID = alarmID
        self.isRecheck = isRecheck
    }

    func perform() async throws -> some IntentResult {
        let id = UUID(uuidString: alarmID)
        if !isRecheck, let id {
            try? AlarmManager.shared.stop(id: id)
        }
        await MainActor.run {
            WakeCoordinator.shared.handleStop(alarmID: id, isRecheck: isRecheck)
        }
        return .result()
    }
}
