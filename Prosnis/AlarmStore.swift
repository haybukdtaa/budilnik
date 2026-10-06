import Foundation
import SwiftUI

/// Список будильников: хранение на диске и синхронизация с системой.
@MainActor
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published private(set) var alarms: [AlarmItem] = []
    @Published var message: String?

    private let service = AlarmService()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("alarms.json")
        load()
    }

    var isAuthorized: Bool { service.isAuthorized }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([AlarmItem].self, from: data) else { return }
        alarms = items
        sort()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func sort() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// Закрыт ли будильник со ставкой для изменений: за 2 часа до звонка и пока идёт проверка.
    func isLocked(_ item: AlarmItem, now: Date = Date()) -> Bool {
        guard item.stakeEnabled, item.isEnabled else { return false }
        if WakeCoordinator.shared.session?.alarmID == item.id { return true }
        guard let next = item.nextOccurrence(after: now) else { return false }
        return next.timeIntervalSince(now) <= WakeRules.lockSeconds
    }

    private func showLockedMessage() {
        message = "Будильник со ставкой нельзя менять за 2 часа до звонка и пока идёт проверка."
    }

    @discardableResult
    func upsert(_ item: AlarmItem) -> Bool {
        if let existing = alarms.first(where: { $0.id == item.id }), isLocked(existing) {
            showLockedMessage()
            return false
        }
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
        sync(item)
        return true
    }

    func delete(_ item: AlarmItem) {
        if let existing = alarms.first(where: { $0.id == item.id }), isLocked(existing) {
            showLockedMessage()
            return
        }
        service.cancel(id: item.id)
        if case .photo(let name) = item.wallpaper {
            WallpaperStorage.delete(name)
        }
        alarms.removeAll { $0.id == item.id }
        save()
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

    func runTest() {
        Task { message = await service.scheduleTest(after: 60) }
    }

    private func sync(_ item: AlarmItem) {
        Task {
            if let error = await service.sync(item) {
                message = error
            }
        }
    }
}
