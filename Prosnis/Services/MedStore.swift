import AlarmKit
import AppIntents
import Foundation
import UserNotifications

/// Лекарства, отметки о приёме и напоминания. Ничего из этого не уходит на сервер и друзьям.
@MainActor
final class MedStore: ObservableObject {
    static let shared = MedStore()

    @Published private(set) var meds: [Medication] = []
    @Published private(set) var records: [DoseRecord] = []
    /// Моменты подъёма (для приёмов «после подъёма»), за последние 60 дней.
    @Published private(set) var wakes: [Date] = []

    private struct Stored: Codable {
        var meds: [Medication] = []
        var records: [DoseRecord] = []
        var wakes: [Date] = []
        /// Поставленные громкие напоминания (системные будильники).
        var alarmIDs: [UUID] = []
        /// Лекарства, о которых уже напомнили купить (сбрасывается, когда запас пополнили).
        var refillNotified: [UUID] = []
    }

    private let file = FileStore<Stored>("medications")
    private var alarmIDs: [UUID] = []
    private var refillNotified: [UUID] = []
    private var loadFailed = false
    private var chain: Task<Void, Never>?

    static let category = "MED"
    static let takenAction = "MED_TAKEN"
    static let snoozeAction = "MED_SNOOZE"
    private static let prefix = "med-"
    /// Сколько тихих напоминаний держать в очереди iOS (всего в ней не больше 64 на приложение).
    static let maxQuiet = 25
    static let maxLoud = 30
    static let snoozeMinutes = 10

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        let stored = result.value ?? Stored()
        meds = stored.meds
        records = stored.records
        wakes = stored.wakes
        alarmIDs = stored.alarmIDs
        refillNotified = stored.refillNotified
        loadFailed = result.state == .unreadable
    }

    func reloadIfNeeded() {
        if loadFailed { reload() }
    }

    private func save() {
        // Файл был закрыт при запуске (телефон не разблокировали): сливаем с ним, ничего не теряя.
        if loadFailed {
            let result = file.loadWithState()
            guard result.state != .unreadable else { return }
            if let disk = result.value {
                let knownMeds = Set(meds.map(\.id))
                meds += disk.meds.filter { !knownMeds.contains($0.id) }
                let knownRecords = Set(records.map(\.id))
                records += disk.records.filter { !knownRecords.contains($0.id) }
                wakes = Array(Set(wakes + disk.wakes)).sorted()
                alarmIDs = Array(Set(alarmIDs + disk.alarmIDs))
                refillNotified = Array(Set(refillNotified + disk.refillNotified))
            }
            loadFailed = false
        }
        file.save(Stored(meds: meds, records: records, wakes: wakes, alarmIDs: alarmIDs, refillNotified: refillNotified))
    }

    /// Системные будильники лекарств: уборка «призраков» их не трогает.
    var scheduledAlarmIDs: Set<UUID> { Set(alarmIDs) }

    /// Время подъёма по дням (начало дня → момент первого подъёма).
    var wakeTimes: [Date: Date] {
        var result: [Date: Date] = [:]
        for wake in wakes.sorted() {
            let day = Calendar.current.startOfDay(for: wake)
            if result[day] == nil { result[day] = wake }
        }
        return result
    }

    // MARK: - Лекарства

    func save(_ med: Medication) {
        var item = med
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.times = Array(Set(item.times)).sorted()
        if let index = meds.firstIndex(where: { $0.id == item.id }) {
            // Запас пополнили: о покупке можно будет напомнить снова.
            if !item.needsRefill { refillNotified.removeAll { $0 == item.id } }
            meds[index] = item
        } else {
            meds.append(item)
        }
        save()
        refresh()
    }

    func delete(_ med: Medication) {
        meds.removeAll { $0.id == med.id }
        records.removeAll { $0.medicationID == med.id }
        refillNotified.removeAll { $0 == med.id }
        save()
        refresh()
    }

    func med(_ id: UUID) -> Medication? { meds.first { $0.id == id } }

    // MARK: - Приёмы

    func doses(from: Date, to: Date) -> [Dose] {
        let wakeTimes = self.wakeTimes
        return meds.flatMap { MedSchedule.doses(for: $0, from: from, to: to, wakeTimes: wakeTimes) }
            .sorted { $0.scheduled < $1.scheduled }
    }

    func todayDoses(now: Date = Date()) -> [Dose] {
        let start = Calendar.current.startOfDay(for: now)
        return doses(from: start, to: start.addingTimeInterval(86400))
    }

    func state(of dose: Dose, now: Date = Date()) -> DoseState {
        MedSchedule.state(of: dose, records: records, now: now)
    }

    /// Отметить приём. Повторная отметка заменяет прежнюю. Принятый приём уменьшает запас.
    func mark(medicationID: UUID, scheduled: Date, _ status: DoseStatus, at: Date = Date()) {
        let dose = Dose(medicationID: medicationID, scheduled: scheduled)
        let previous = MedSchedule.record(for: dose, in: records)
        records.removeAll { $0.id == previous?.id }
        records.append(DoseRecord(medicationID: medicationID, scheduled: scheduled, status: status, at: at))
        if let index = meds.firstIndex(where: { $0.id == medicationID }), let stock = meds[index].stock {
            let wasTaken = previous?.status == .taken
            if status == .taken && !wasTaken { meds[index].stock = max(0, stock - meds[index].unitsPerDose) }
            if status != .taken && wasTaken { meds[index].stock = stock + meds[index].unitsPerDose }
        }
        // Отметки старше года не нужны.
        let cutoff = Date().addingTimeInterval(-366 * 86400)
        records.removeAll { $0.scheduled < cutoff }
        save()
        notifyRefillIfNeeded(medicationID)
        refresh()
    }

    /// Снять отметку (ошибся).
    func unmark(_ dose: Dose) {
        guard let record = MedSchedule.record(for: dose, in: records) else { return }
        records.removeAll { $0.id == record.id }
        if record.status == .taken, let index = meds.firstIndex(where: { $0.id == dose.medicationID }), let stock = meds[index].stock {
            meds[index].stock = stock + meds[index].unitsPerDose
        }
        save()
        refresh()
    }

    /// Утро удалось: приёмы «после подъёма» переносятся от момента подъёма.
    func morningCompleted(at date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard wakeTimes[day] == nil else { return }
        wakes.append(date)
        wakes.removeAll { date.timeIntervalSince($0) > 60 * 86400 }
        save()
        if meds.contains(where: \.isAfterWake) { refresh() }
    }

    // MARK: - Напоминания

    private var showNames: Bool { AppSettings.shared.data.medsShowNames }

    /// Переставляет напоминания. Вызовы идут по очереди.
    func refresh() {
        let previous = chain
        chain = Task {
            await previous?.value
            await performRefresh()
        }
    }

    private func performRefresh() async {
        // Снимаем прежние.
        for id in alarmIDs { AlarmService.shared.cancel(id: id) }
        alarmIDs = []
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
            $0.hasPrefix(MedStore.prefix) && !$0.hasPrefix(MedStore.prefix + "snooze")
        })

        guard AppSettings.shared.data.medsEnabled else {
            save()
            return
        }
        let now = Date()
        let upcoming = doses(from: now, to: now.addingTimeInterval(3 * 86400))
            .filter { MedSchedule.record(for: $0, in: records) == nil }
        var loud = 0
        var quiet = 0
        for dose in upcoming {
            guard let med = med(dose.medicationID) else { continue }
            if med.loud {
                guard loud < MedStore.maxLoud else { continue }
                if let id = await AlarmService.shared.scheduleMedAlarm(
                    at: dose.scheduled, title: alarmTitle(med), medicationID: med.id, scheduled: dose.scheduled
                ) {
                    alarmIDs.append(id)
                    loud += 1
                }
            } else {
                guard quiet < MedStore.maxQuiet else { continue }
                await addNotification(id: MedStore.prefix + dose.id, med: med, scheduled: dose.scheduled, fire: dose.scheduled)
                quiet += 1
            }
        }
        save()
    }

    private func alarmTitle(_ med: Medication) -> String {
        showNames ? "\(med.name)\(med.meal.hint.map { ", \($0)" } ?? "")" : "Время принять лекарство"
    }

    private func addNotification(id: String, med: Medication, scheduled: Date, fire: Date) async {
        let content = UNMutableNotificationContent()
        content.title = "Время принять лекарство"
        content.body = MedSchedule.reminderBody(med, showName: showNames)
        content.sound = .default
        content.categoryIdentifier = MedStore.category
        content.userInfo = ["med": med.id.uuidString, "scheduled": scheduled.timeIntervalSince1970]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        ))
    }

    /// «Через 10 минут»: ещё одно напоминание о том же приёме.
    func snooze(medicationID: UUID, scheduled: Date) async {
        guard let med = med(medicationID) else { return }
        let fire = Date().addingTimeInterval(Double(MedStore.snoozeMinutes) * 60)
        if med.loud {
            if let id = await AlarmService.shared.scheduleMedAlarm(at: fire, title: alarmTitle(med), medicationID: med.id, scheduled: scheduled) {
                alarmIDs.append(id)
                save()
            }
        } else {
            await addNotification(id: MedStore.prefix + "snooze-\(UUID().uuidString)", med: med, scheduled: scheduled, fire: fire)
        }
    }

    /// Нажали кнопку на тихом уведомлении.
    func handleNotificationAction(_ action: String, userInfo: [AnyHashable: Any]) async {
        guard let text = userInfo["med"] as? String, let id = UUID(uuidString: text),
              let seconds = userInfo["scheduled"] as? Double else { return }
        let scheduled = Date(timeIntervalSince1970: seconds)
        switch action {
        case MedStore.takenAction: mark(medicationID: id, scheduled: scheduled, .taken)
        case MedStore.snoozeAction: await snooze(medicationID: id, scheduled: scheduled)
        default: break
        }
    }

    static func registerCategory() {
        let taken = UNNotificationAction(identifier: takenAction, title: "Принял(а)", options: [])
        let later = UNNotificationAction(identifier: snoozeAction, title: "Через \(snoozeMinutes) минут", options: [])
        let category = UNNotificationCategory(identifier: MedStore.category, actions: [taken, later], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Запас подходит к концу: одно напоминание купить.
    private func notifyRefillIfNeeded(_ id: UUID) {
        guard let med = med(id), med.needsRefill, !refillNotified.contains(id) else { return }
        refillNotified.append(id)
        save()
        let content = UNMutableNotificationContent()
        content.title = "Лекарство заканчивается"
        content.body = showNames
            ? "\(med.name): осталось на \(Words.days(med.daysLeft ?? 0)). Пора купить."
            : "Одно из лекарств скоро закончится. Пора купить."
        content.sound = .default
        let request = UNNotificationRequest(identifier: MedStore.prefix + "refill-\(id.uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}

/// «Принял(а)» на громком напоминании: отмечает приём, не открывая приложение.
struct MedTakenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Принял(а) лекарство"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Лекарство") var medicationID: String
    @Parameter(title: "Время приёма") var scheduled: Double
    @Parameter(title: "Звонок") var systemID: String

    init() {
        medicationID = ""
        scheduled = 0
        systemID = ""
    }

    init(medicationID: UUID, scheduled: Date, systemID: UUID) {
        self.medicationID = medicationID.uuidString
        self.scheduled = scheduled.timeIntervalSince1970
        self.systemID = systemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let ringing = UUID(uuidString: systemID) { try? AlarmManager.shared.stop(id: ringing) }
        guard let id = UUID(uuidString: medicationID) else { return .result() }
        let at = Date(timeIntervalSince1970: scheduled)
        await MainActor.run { MedStore.shared.mark(medicationID: id, scheduled: at, .taken) }
        return .result()
    }
}

/// «Через 10 минут» на громком напоминании.
struct MedSnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Напомнить позже"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Лекарство") var medicationID: String
    @Parameter(title: "Время приёма") var scheduled: Double
    @Parameter(title: "Звонок") var systemID: String

    init() {
        medicationID = ""
        scheduled = 0
        systemID = ""
    }

    init(medicationID: UUID, scheduled: Date, systemID: UUID) {
        self.medicationID = medicationID.uuidString
        self.scheduled = scheduled.timeIntervalSince1970
        self.systemID = systemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let ringing = UUID(uuidString: systemID) { try? AlarmManager.shared.stop(id: ringing) }
        guard let id = UUID(uuidString: medicationID) else { return .result() }
        let at = Date(timeIntervalSince1970: scheduled)
        await MedStore.shared.snooze(medicationID: id, scheduled: at)
        return .result()
    }
}
