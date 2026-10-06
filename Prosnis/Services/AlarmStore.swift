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

    private var context: ScheduleContext { AppSettings.shared.scheduleContext }

    private func load() {
        let result = file.loadWithState()
        alarms = result.value ?? []
        loadFailed = result.state == .unreadable
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

    /// Закрыт ли будильник со ставкой для изменений: за 2 часа до звонка и пока идёт проверка.
    func isLocked(_ item: AlarmItem, now: Date = TrustedClock.now) -> Bool {
        guard item.stakeEnabled, item.isEnabled else { return false }
        if WakeCoordinator.shared.session?.alarmID == item.id { return true }
        if WakeCoordinator.shared.session?.queuedAlarmIDs?.contains(item.id) == true { return true }
        // Звонок только что был, а утро ещё не записано: менять нельзя, иначе можно уйти от ставки.
        if let last = lastOccurrence(of: item, onOrBefore: now),
           now.timeIntervalSince(last) < WakeRules.windowSeconds + 60,
           last > (item.createdAt ?? .distantPast),
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
        item.updatedAt = Date()
        if item.weekdays.isEmpty && item.effectiveHolidayMode != .workCalendar {
            // Одноразовый будильник взводится заново при каждом сохранении: звонит в ближайшее время, а не в прошлое.
            item.createdAt = Date()
        }
        if !AppSettings.shared.data.isAdult { item.stakeEnabled = false }
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
        service.cancelAll(for: item.id)
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

    func runTest() {
        Task { message = await service.scheduleTest(after: 60) }
    }

    private func sync(_ item: AlarmItem) {
        let context = self.context
        Task {
            if let error = await service.sync(item, context: context) {
                message = error
            }
        }
    }
}
