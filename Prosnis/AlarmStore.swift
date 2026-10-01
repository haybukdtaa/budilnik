import Foundation
import SwiftUI

/// Список будильников: хранение на диске и синхронизация с системой.
@MainActor
final class AlarmStore: ObservableObject {
    @Published private(set) var alarms: [AlarmItem] = []
    @Published var message: String?

    private let service = AlarmService()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("alarms.json")
        load()
    }

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

    func upsert(_ item: AlarmItem) {
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
    }

    func delete(_ item: AlarmItem) {
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
