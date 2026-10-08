import Foundation
import SwiftUI

/// Список будильников: хранение на диске и синхронизация с системой.
@MainActor
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published private(set) var alarms: [AlarmItem] = []
    @Published var message: String?

    private let service = AlarmService.shared
    private let file = FileStore<[AlarmItem]>("alarms")
    private static let lastDatedRefreshKey = "lastDatedRefresh"

    private var loadFailed = false

    private init() {
        load()
    }

    func reloadIfNeeded() {
        if loadFailed { load() }
    }

    var isAuthorized: Bool { service.isAuthorized }

    /// Когда будильник в последний раз создан, включён или изменён. Звонки до этого момента не считаются.
    static func changedAt(_ item: AlarmItem) -> Date {
        max(item.createdAt ?? .distantPast, item.updatedAt ?? .distantPast)
    }

    func isScheduleFailed(_ item: AlarmItem) -> Bool { item.isEnabled && service.isFailed(item.id) }

    private var context: ScheduleContext { AppSettings.shared.scheduleContext }

    private func load() {
        let result = file.loadWithState()
        alarms = result.value ?? []
        loadFailed = result.state == .unreadable
        // Данные старых версий без даты создания: считаем созданными сейчас, иначе одноразовый будильник «звонил» бы в 1 году.
        if alarms.contains(where: { $0.createdAt == nil }) {
            let now = Date()
            for index in alarms.indices where alarms[index].createdAt == nil {
                alarms[index].createdAt = now
            }
            if result.state == .loaded { save() }
        }
        sort()
    }

    func reload() { load() }

    private func save() { file.save(alarms) }

    private func sort() {
        alarms.sort { ($0.isFajr ? 1 : 0, $0.hour, $0.minute) < ($1.isFajr ? 1 : 0, $1.hour, $1.minute) }
    }

    private func enqueueSync(_ item: AlarmItem) {
        if item.isPrayerRelated && !AppSettings.shared.data.privacy.syncPrayerData { return }
        SyncEngine.shared.enqueue(.alarm, id: item.id, value: item, sensitive: item.isPrayerRelated)
    }

    func nextOccurrence(of item: AlarmItem, after now: Date = TrustedClock.now) -> Date? {
        if let once = ScheduleCalculator.onceDate(for: item, context: context) {
            return once > now ? once : nil
        }
        return ScheduleCalculator.nextOccurrence(for: item, after: now, context: context)
    }

    func lastOccurrence(of item: AlarmItem, onOrBefore now: Date) -> Date? {
        ScheduleCalculator.lastOccurrence(for: item, onOrBefore: now, context: context)
    }

    /// Ставка действует: включена, сумма больше нуля и человек согласился с текущими условиями на эту сумму.
    func isStakeActive(_ item: AlarmItem) -> Bool {
        item.stakeEnabled && item.stakeAmount > 0
            && !StakeTerms.needsConsent(AppSettings.shared.data.stakeConsent, amount: item.stakeAmount)
    }

    /// Включённые будильники со ставкой, для которых нужно заново согласиться с условиями (условия изменились).
    var alarmsNeedingConsent: [AlarmItem] {
        alarms.filter { $0.isEnabled && $0.stakeEnabled && $0.stakeAmount > 0 && !isStakeActive($0) }
    }

    /// Закрыт ли будильник со ставкой для изменений: за 2 часа до звонка и пока идёт проверка.
    func isLocked(_ item: AlarmItem, now: Date = TrustedClock.now) -> Bool {
        guard isStakeActive(item), item.isEnabled else { return false }
        // После смены пояса утро ждёт своего второго времени звонка: пока оно не решено, менять нельзя.
        if WakeCoordinator.shared.hasUnresolvedMorning(item, now: now) { return true }
        if WakeCoordinator.shared.session?.alarmID == item.id { return true }
        if WakeCoordinator.shared.session?.queuedAlarmIDs?.contains(item.id) == true { return true }
        // Звонок только что был, а утро ещё не записано: менять нельзя, иначе можно уйти от ставки.
        if let last = lastOccurrence(of: item, onOrBefore: now),
           now.timeIntervalSince(last) < WakeRules.windowSeconds + 60,
           last > AlarmStore.changedAt(item),
           !JournalStore.shared.hasEntry(alarmID: item.id, near: last) {
            return true
        }
        guard let next = nextOccurrence(of: item, after: now) else { return false }
        return next.timeIntervalSince(now) <= WakeRules.lockSeconds
    }

    private func showLockedMessage() {
        message = "Будильник со ставкой нельзя менять за 2 часа до звонка и пока идёт проверка."
    }

    @discardableResult
    func upsert(_ draft: AlarmItem) -> Bool {
        // Сначала записываем пропущенные звонки по старым настройкам.
        WakeCoordinator.shared.reconcile()
        if let existing = alarms.first(where: { $0.id == draft.id }), isLocked(existing) {
            showLockedMessage()
            return false
        }
        var item = draft
        let now = TrustedClock.now
        item.updatedAt = now
        if item.weekdays.isEmpty && item.effectiveHolidayMode != .workCalendar {
            // Одноразовый будильник взводится заново при каждом сохранении: звонит в ближайшее время, а не в прошлое.
            item.createdAt = now
        }
        if !AppSettings.shared.data.isAdult { item.stakeEnabled = false }
        if item.stakeAmount <= 0 { item.stakeEnabled = false }
        if item.stakeEnabled && item.isEnabled {
            // Ставка без согласия с текущими условиями или без разрешения на будильники не включается.
            if StakeTerms.needsConsent(AppSettings.shared.data.stakeConsent, amount: item.stakeAmount) {
                message = "Сначала согласитесь с условиями ставки: откройте будильник и нажмите «Сохранить»."
                return false
            }
            if !service.isAuthorized {
                message = "Чтобы включить будильник со ставкой, разрешите будильники в Настройках iPhone."
                return false
            }
        }
        if item.effectiveTask == .qr && (item.qrCode ?? "").isEmpty { item.taskKind = .typing }

        if let index = alarms.firstIndex(where: { $0.id == item.id }) {
            if case .photo(let old) = alarms[index].wallpaper, alarms[index].wallpaper != item.wallpaper {
                WallpaperStorage.delete(old)
            }
            alarms[index] = item
        } else {
            alarms.append(item)
        }
        sort()
        save()
        enqueueSync(item)
        sync(item)
        return true
    }

    func delete(_ item: AlarmItem) {
        WakeCoordinator.shared.reconcile()
        if let existing = alarms.first(where: { $0.id == item.id }), isLocked(existing) {
            showLockedMessage()
            return
        }
        let id = item.id
        Task { await service.remove(id) }
        if case .photo(let name) = item.wallpaper {
            WallpaperStorage.delete(name)
        }
        alarms.removeAll { $0.id == item.id }
        save()
        if !(item.isPrayerRelated && !AppSettings.shared.data.privacy.syncPrayerData) {
            SyncEngine.shared.enqueueDeletion(.alarm, id: item.id, sensitive: item.isPrayerRelated)
        }
    }

    func setEnabled(_ item: AlarmItem, _ isOn: Bool) {
        var copy = item
        copy.isEnabled = isOn
        upsert(copy)
    }

    /// Добавляет будильники, восстановленные с сервера (которых ещё нет на телефоне), и ставит их.
    func mergeRestored(_ items: [AlarmItem]) {
        let known = Set(alarms.map(\.id))
        let added = items.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        alarms += added
        sort()
        save()
        for item in added where item.isEnabled { sync(item) }
    }

    /// Выключает одноразовый будильник после срабатывания, без обращения к системе.
    func disableSilently(_ id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }), alarms[index].isEnabled else { return }
        alarms[index].isEnabled = false
        save()
    }

    /// Переставляет будильники на конкретные даты (Фаджр и календарь РФ) на 10 дней вперёд.
    /// Без принуждения — не чаще раза в 6 часов.
    func refreshDatedAlarms(force: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date()
        if !force, let last = defaults.object(forKey: AlarmStore.lastDatedRefreshKey) as? Date,
           now.timeIntervalSince(last) < 6 * 3600 { return }
        defaults.set(now, forKey: AlarmStore.lastDatedRefreshKey)
        for item in alarms where item.isEnabled && item.needsDatedSchedule {
            sync(item)
        }
    }

    /// Запоминает ожидаемые звонки будильников с заданием на ближайшие дни (защита от перевода часов).
    func refreshExpected() {
        let context = self.context
        for item in alarms { service.recordExpected(item, context: context) }
    }

    /// Переставляет будильники, которые не удалось поставить (например, разрешение дали позже).
    func resyncFailed() {
        guard service.isAuthorized else { return }
        for item in alarms where isScheduleFailed(item) {
            sync(item)
        }
    }

    /// Убирает системные будильники-«призраки» и фото фонов, которые больше ни к чему не относятся.
    func cleanupOrphans() {
        var known = Set(alarms.map(\.id))
        if let recheck = WakeCoordinator.shared.session?.recheckAlarmID { known.insert(recheck) }
        service.pruneOrphans(known: known)
        let used = Set(alarms.compactMap { alarm -> String? in
            if case .photo(let name) = alarm.wallpaper { return name }
            return nil
        })
        WallpaperStorage.deleteAll(except: used)
    }

    func runTest() {
        Task { message = await service.scheduleTest(after: 60) }
    }

    private func sync(_ item: AlarmItem) {
        let context = self.context
        Task {
            if let error = await service.sync(item, context: context) {
                message = error
            }
            if let current = alarms.first(where: { $0.id == item.id }) {
                service.recordExpected(current, context: context)
            }
            await DeadlineNotifications.refresh()
        }
    }
}
