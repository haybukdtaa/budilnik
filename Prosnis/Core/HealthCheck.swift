import AVFoundation
import CoreMotion
import Foundation
import UserNotifications

/// «Здоровье будильников»: всё, из-за чего будильник мог бы не зазвонить, в одном списке.
@MainActor
final class HealthCheck: ObservableObject {
    static let shared = HealthCheck()

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isOK: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var backups: [AppFiles.BackupFile] = []

    var issueCount: Int { items.filter { !$0.isOK }.count + (backups.isEmpty ? 0 : 1) }

    /// Когда истекает подпись приложения (бесплатный Apple ID — 7 дней). nil — подписи с датой нет (App Store, симулятор).
    static var signatureExpiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    func refresh() async {
        var list: [Item] = []

        let alarmsAllowed = AlarmService.shared.isAuthorized
        list.append(Item(
            id: "alarm-permission", title: "Разрешение на будильники",
            detail: alarmsAllowed ? "Включено" : "Выключено: будильники не зазвонят. Включите в Настройки → Prosnis.",
            isOK: alarmsAllowed
        ))

        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let notificationsOK = notifications == .authorized || notifications == .provisional || notifications == .ephemeral
        list.append(Item(
            id: "notifications", title: "Уведомления",
            detail: notificationsOK ? "Включены" : "Выключены: не придут напоминания о лекарствах и итогах. Будильники от этого не зависят.",
            isOK: notificationsOK
        ))

        if AppConfig.serverURL != nil {
            let filled = LegalOperator.isFilled
            list.append(Item(
                id: "legal-operator", title: "Данные оператора в документах",
                detail: filled ? "Заполнены" : "Не заполнены: в политике и соглашении остались заглушки. Заполните LegalOperator до запуска сервера.",
                isOK: filled
            ))
        }

        let enabled = AlarmStore.shared.alarms.filter(\.isEnabled)
        if enabled.contains(where: { $0.effectiveTask == .steps }) {
            let status = CMPedometer.authorizationStatus()
            let ok = CMPedometer.isStepCountingAvailable() && status != .denied && status != .restricted
            list.append(Item(
                id: "motion", title: "Доступ к движению (задание «шаги»)",
                detail: ok ? "Есть" : "Нет: задание заменится печатью. Включите в Настройки → Prosnis → Движение и фитнес.",
                isOK: ok
            ))
        }
        if enabled.contains(where: { $0.effectiveTask == .qr }) {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let ok = status == .authorized || status == .notDetermined
            list.append(Item(
                id: "camera", title: "Доступ к камере (задание «код»)",
                detail: ok ? "Есть" : "Нет: задание заменится печатью. Включите в Настройки → Prosnis → Камера.",
                isOK: ok
            ))
        }

        let failed = enabled.filter { AlarmStore.shared.isScheduleFailed($0) }
        list.append(Item(
            id: "scheduled", title: "Все включённые будильники стоят в системе",
            detail: failed.isEmpty ? "Да" : "Не поставлены: " + failed.map { "\($0.timeText) «\($0.displayTitle)»" }.joined(separator: ", "),
            isOK: failed.isEmpty
        ))

        let wanted = AlarmStore.shared.wantedSystemIDs()
        let extra = AlarmService.shared.systemAlarms(known: wanted.known, enabledKeys: wanted.enabledKeys).filter(\.isExtra).count
        list.append(Item(
            id: "extra", title: "Лишние будильники в системе",
            detail: extra == 0 ? "Нет" : "Найдено: \(extra). Они снимутся при открытии приложения; список — в «Системные будильники».",
            isOK: extra == 0
        ))

        if let expiry = HealthCheck.signatureExpiry {
            let days = Int(expiry.timeIntervalSinceNow / 86400)
            let ok = days >= 2
            list.append(Item(
                id: "signature", title: "Подпись приложения",
                detail: days < 0
                    ? "Истекла: будильники не работают. Переустановите приложение через Sideloadly."
                    : "Действует до \(Format.dateTime(expiry)) (осталось дней: \(days)). После этого приложение нужно переустановить.",
                isOK: ok
            ))
        }

        items = list
        backups = AppFiles.corruptBackups()
    }

    /// Перечитывает данные после возврата из копии.
    func reloadStores() {
        AlarmStore.shared.reload()
        WakeCoordinator.shared.reload()
        JournalStore.shared.reload()
        ChallengeStore.shared.reload()
        PaymentsStore.shared.reload()
        AppSettings.shared.reload()
        MedStore.shared.reload()
        MedStore.shared.refresh()
    }
}
