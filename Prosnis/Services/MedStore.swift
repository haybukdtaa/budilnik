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
    /// Моменты подъёма (для приёмов «после подъёма»), за последний год.
    @Published private(set) var wakes: [Date] = []

    private struct Stored: Codable {
        var meds: [Medication] = []
        var records: [DoseRecord] = []
        var wakes: [Date] = []
        /// Поставленные громкие напоминания (системные будильники).
        var alarmIDs: [UUID] = []
        /// Громкие «Через 10 минут»: перестановка их не трогает, снимаются при отметке приёма.
        var snoozeAlarms: [String: UUID]? = [:]
        /// Лекарства, о которых уже напомнили купить (сбрасывается, когда запас пополнили).
        var refillNotified: [UUID] = []
    }

    private let file = FileStore<Stored>("medications")
    private var alarmIDs: [UUID] = []
    /// Ключ — «id лекарства|секунды приёма».
    private var snoozeAlarms: [String: UUID] = [:]
    private var refillNotified: [UUID] = []
    private var loadFailed = false
    private var chain: Task<Void, Never>?

    nonisolated static let category = "MED"
    nonisolated static let takenAction = "MED_TAKEN"
    nonisolated static let snoozeAction = "MED_SNOOZE"
    private static let prefix = "med-"
    private static let snoozePrefix = "med-snooze-"
    private static let refillPrefix = "med-refill-"
    private static let continueID = "med-continue"
    /// Сколько тихих напоминаний держать в очереди iOS (всего в ней не больше 64 на приложение).
    static let maxQuiet = 25
    static let maxLoud = 40
    static let snoozeMinutes = 10
    /// На сколько дней вперёд ставятся напоминания.
    static let horizonDays = 7

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
        snoozeAlarms = stored.snoozeAlarms ?? [:]
        refillNotified = stored.refillNotified
        loadFailed = result.state == .unreadable
    }

    /// Файл был закрыт (до первой разблокировки): сливаем его с тем, что отметили за это время.
    func reloadIfNeeded() {
        if loadFailed { save() }
    }

    private func save() {
        if loadFailed {
            let result = file.loadWithState()
            guard result.state != .unreadable else { return }
            if let disk = result.value {
                let diskRecordIDs = Set(disk.records.map(\.id))
                let knownMeds = Set(meds.map(\.id))
                meds += disk.meds.filter { !knownMeds.contains($0.id) }
                let knownRecords = Set(records.map(\.id))
                records += disk.records.filter { !knownRecords.contains($0.id) }
                wakes = Array(Set(wakes + disk.wakes)).sorted()
                alarmIDs = Array(Set(alarmIDs + disk.alarmIDs))
                snoozeAlarms.merge(disk.snoozeAlarms ?? [:]) { mine, _ in mine }
                refillNotified = Array(Set(refillNotified + disk.refillNotified))
                // Отметки, сделанные пока файл был закрыт, ещё не списали запас: списываем сейчас.
                for index in records.indices where records[index].status == .taken && records[index].deducted == nil
                    && !diskRecordIDs.contains(records[index].id) {
                    records[index].deducted = deductStock(records[index].medicationID)
                }
            }
            loadFailed = false
        }
        file.save(Stored(meds: meds, records: records, wakes: wakes, alarmIDs: alarmIDs,
                         snoozeAlarms: snoozeAlarms, refillNotified: refillNotified))
    }

    /// Системные будильники лекарств: уборка «призраков» их не трогает.
    var scheduledAlarmIDs: Set<UUID> { Set(alarmIDs).union(snoozeAlarms.values) }

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
            let old = meds[index]
            // Расписание изменилось: прежнее остаётся для прошлых дней, календарь не переписывается.
            if old.times != item.times || old.afterWakeMinutes != item.afterWakeMinutes || old.afterWakeFallback != item.afterWakeFallback {
                var history = old.history ?? []
                history.append(ScheduleVersion(times: old.times, afterWakeMinutes: old.afterWakeMinutes,
                                               afterWakeFallback: old.afterWakeFallback, until: Date()))
                item.history = history
            }
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
        cancelSnoozes { $0.hasPrefix(med.id.uuidString) }
        save()
        refresh()
    }

    func med(_ id: UUID) -> Medication? { meds.first { $0.id == id } }

    // MARK: - Приёмы

    func doses(from: Date, to: Date) -> [Dose] {
        let wakeTimes = self.wakeTimes
        return meds.flatMap { MedSchedule.doses(for: $0, from: from, to: to, wakeTimes: wakeTimes, records: records) }
            .sorted { $0.scheduled < $1.scheduled }
    }

    func doses(of med: Medication, from: Date, to: Date) -> [Dose] {
        MedSchedule.doses(for: med, from: from, to: to, wakeTimes: wakeTimes, records: records)
    }

    func todayDoses(now: Date = Date()) -> [Dose] {
        let start = Calendar.current.startOfDay(for: now)
        return doses(from: start, to: start.addingTimeInterval(86400))
    }

    func state(of dose: Dose, now: Date = Date()) -> DoseState {
        MedSchedule.state(of: dose, records: records, now: now)
    }

    /// Списывает приём с запаса. Возвращает, сколько списано (nil — запас не считаем).
    private func deductStock(_ medicationID: UUID) -> Int? {
        guard let index = meds.firstIndex(where: { $0.id == medicationID }), let stock = meds[index].stock else { return nil }
        let amount = min(stock, meds[index].unitsPerDose)
        meds[index].stock = stock - amount
        return amount
    }

    /// Возвращает в запас ровно то, что списал этот приём.
    private func returnStock(_ record: DoseRecord) {
        guard let amount = record.deducted, amount > 0,
              let index = meds.firstIndex(where: { $0.id == record.medicationID }), let stock = meds[index].stock else { return }
        meds[index].stock = stock + amount
    }

    /// Отметить приём. Повторная отметка заменяет прежнюю. Принятый приём уменьшает запас.
    func mark(medicationID: UUID, scheduled: Date, _ status: DoseStatus, at: Date = Date()) {
        let dose = Dose(medicationID: medicationID, scheduled: scheduled)
        let previous = MedSchedule.record(for: dose, in: records)
        if let previous, previous.status == status { return }
        if let previous {
            records.removeAll { $0.id == previous.id }
            returnStock(previous)
        }
        var record = DoseRecord(medicationID: medicationID, scheduled: scheduled, status: status, at: at)
        if status == .taken && !loadFailed { record.deducted = deductStock(medicationID) }
        records.append(record)
        // Отметки старше года не нужны.
        let cutoff = Date().addingTimeInterval(-366 * 86400)
        records.removeAll { $0.scheduled < cutoff }
        cancelSnoozes { $0 == MedStore.snoozeKey(medicationID, scheduled) }
        save()
        notifyRefillIfNeeded(medicationID)
        refresh()
    }

    /// Снять отметку (ошибся).
    func unmark(_ dose: Dose) {
        guard let record = MedSchedule.record(for: dose, in: records) else { return }
        records.removeAll { $0.id == record.id }
        returnStock(record)
        save()
        refresh()
    }

    /// Утро удалось: приёмы «после подъёма» отсчитываются от звонка будильника этого утра.
    func morningCompleted(ring: Date) {
        let day = Calendar.current.startOfDay(for: ring)
        guard wakeTimes[day] == nil else { return }
        wakes.append(ring)
        wakes.removeAll { ring.timeIntervalSince($0) > 400 * 86400 }
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

    /// Дождаться, пока напоминания переставятся (для кнопок на экране блокировки: iOS может усыпить приложение).
    func waitForRefresh() async {
        await chain?.value
    }

    private func performRefresh() async {
        // Файл закрыт (до первой разблокировки): не трогаем напоминания, иначе снимем всё и ничего не поставим.
        guard !loadFailed else { return }
        let center = UNUserNotificationCenter.current()
        let enabled = AppSettings.shared.data.medsEnabled && !meds.isEmpty

        // Снимаем прежние. Отложенные («Через 10 минут») и напоминание купить не трогаем, пока модуль включён.
        for id in alarmIDs { AlarmService.shared.cancel(id: id) }
        alarmIDs = []
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { id in
            guard id.hasPrefix(MedStore.prefix) else { return false }
            if !enabled { return true }
            return !id.hasPrefix(MedStore.snoozePrefix) && !id.hasPrefix(MedStore.refillPrefix)
        })
        if !enabled {
            cancelSnoozes { _ in true }
            save()
            return
        }

        let now = Date()
        let horizon = now.addingTimeInterval(Double(MedStore.horizonDays) * 86400)
        let upcoming = doses(from: now, to: horizon).filter { MedSchedule.record(for: $0, in: records) == nil }
        var loud = 0
        var quiet = 0
        var lastCovered: Date?
        var allCovered = true
        for dose in upcoming {
            guard let med = med(dose.medicationID) else { continue }
            var placed = false
            if med.loud && loud < MedStore.maxLoud,
               let id = await AlarmService.shared.scheduleMedAlarm(at: dose.scheduled, title: alarmTitle(med), medicationID: med.id, scheduled: dose.scheduled) {
                alarmIDs.append(id)
                loud += 1
                placed = true
            }
            // Тихое уведомление, а для громкого без разрешения на будильники — вместо него.
            if !placed && quiet < MedStore.maxQuiet {
                await addNotification(id: MedStore.prefix + dose.id, med: med, scheduled: dose.scheduled, fire: dose.scheduled)
                quiet += 1
                placed = true
            }
            if placed {
                lastCovered = dose.scheduled
            } else {
                allCovered = false
                break
            }
        }
        // Напоминания закончатся раньше, чем через неделю: попросим открыть приложение, чтобы они продолжились.
        if !allCovered, let lastCovered {
            let content = UNMutableNotificationContent()
            content.title = "Откройте Prosnis"
            content.body = "Чтобы напоминания о лекарствах продолжились, откройте приложение."
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: lastCovered.addingTimeInterval(300))
            try? await center.add(UNNotificationRequest(identifier: MedStore.continueID, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        save()
    }

    /// Громкие напоминания включены, а разрешения на будильники нет: приходят тихие.
    var loudWithoutPermission: Bool {
        meds.contains(where: \.loud) && !AlarmService.shared.isAuthorized
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

    private static func snoozeKey(_ medicationID: UUID, _ scheduled: Date) -> String {
        "\(medicationID.uuidString)|\(Int(scheduled.timeIntervalSince1970))"
    }

    /// Снимает отложенные напоминания (громкие и тихие), чьи ключи подходят.
    private func cancelSnoozes(where matches: @escaping (String) -> Bool) {
        for (key, id) in snoozeAlarms where matches(key) {
            AlarmService.shared.cancel(id: id)
            snoozeAlarms[key] = nil
        }
        // Тихие отложенные: ключ — в идентификаторе «med-snooze-<ключ>#<случайное>».
        let center = UNUserNotificationCenter.current()
        let prefix = MedStore.snoozePrefix
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { id in
                guard id.hasPrefix(prefix) else { return false }
                let key = String(id.dropFirst(prefix.count)).components(separatedBy: "#").first ?? ""
                return matches(key)
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// «Через 10 минут»: ещё одно напоминание о том же приёме.
    func snooze(medicationID: UUID, scheduled: Date) async {
        guard let med = med(medicationID) else { return }
        let key = MedStore.snoozeKey(medicationID, scheduled)
        cancelSnoozes { $0 == key }
        let fire = Date().addingTimeInterval(Double(MedStore.snoozeMinutes) * 60)
        if med.loud, let id = await AlarmService.shared.scheduleMedAlarm(at: fire, title: alarmTitle(med), medicationID: med.id, scheduled: scheduled) {
            snoozeAlarms[key] = id
            save()
        } else {
            await addNotification(id: MedStore.snoozePrefix + key + "#" + UUID().uuidString, med: med, scheduled: scheduled, fire: fire)
        }
    }

    /// Нажали кнопку на тихом уведомлении.
    func handleNotificationAction(_ action: String, userInfo: [AnyHashable: Any]) async {
        guard let text = userInfo["med"] as? String, let id = UUID(uuidString: text),
              let seconds = userInfo["scheduled"] as? Double, med(id) != nil else { return }
        let scheduled = Date(timeIntervalSince1970: seconds)
        switch action {
        case MedStore.takenAction: mark(medicationID: id, scheduled: scheduled, .taken)
        case MedStore.snoozeAction: await snooze(medicationID: id, scheduled: scheduled)
        default: break
        }
        await waitForRefresh()
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
        let request = UNNotificationRequest(identifier: MedStore.refillPrefix + id.uuidString, content: content,
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
        // iOS может усыпить приложение сразу после ответа: ждём, пока напоминания переставятся.
        await MedStore.shared.waitForRefresh()
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
        await MedStore.shared.waitForRefresh()
        return .result()
    }
}
