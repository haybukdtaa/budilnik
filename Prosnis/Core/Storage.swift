import Foundation

enum FileLoadState: Equatable {
    case missing     // файла нет: первый запуск
    case loaded
    case unreadable  // файл есть, но закрыт (телефон ещё не разблокировали после включения)
    case corrupt     // файл есть, но не читается как данные (несовместимая версия)
}

/// Список, который можно прочитать по одной записи: непонятные записи пропускаются, а не обнуляют весь список.
protocol LossyDecodable {
    static func lossyDecode(_ data: Data) -> Self?
}

private struct LossyBox<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Array: LossyDecodable where Element: Decodable {
    static func lossyDecode(_ data: Data) -> [Element]? {
        guard let boxes = try? JSONDecoder().decode([LossyBox<Element>].self, from: data) else { return nil }
        let items = boxes.compactMap(\.value)
        // Не прочиталась ни одна запись из непустого списка: это не «чуть повреждён», а другой формат.
        if items.isEmpty && !boxes.isEmpty { return nil }
        return items
    }
}

/// Одно значение Codable в файле Documents/<name>.json.
/// Никогда не перезаписывает файл, который сейчас нельзя прочитать: иначе можно потерять данные.
struct FileStore<Value: Codable> {
    let url: URL
    private let protection: Data.WritingOptions

    init(_ name: String, protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication) {
        url = AppFiles.documents.appendingPathComponent(name + ".json")
        self.protection = protection
    }

    func loadWithState() -> (value: Value?, state: FileLoadState) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, .missing) }
        guard let data = try? Data(contentsOf: url) else { return (nil, .unreadable) }
        if let value = try? JSONDecoder().decode(Value.self, from: data) { return (value, .loaded) }
        // Список с одной непонятной записью (например, новой версии) не теряется целиком: читаем то, что читается.
        // Исходный файл при первой же записи сохраняется рядом копией (см. save).
        if let lossy = (Value.self as Any.Type) as? LossyDecodable.Type,
           let salvaged = lossy.lossyDecode(data) as? Value {
            return (salvaged, .loaded)
        }
        return (nil, .corrupt)
    }

    func load() -> Value? { loadWithState().value }

    /// Сохраняет. Возвращает false, если файл существует, но сейчас закрыт.
    /// Несовместимый старый файл перед перезаписью сохраняется рядом копией.
    @discardableResult
    func save(_ value: Value) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            guard let existing = try? Data(contentsOf: url) else { return false }
            if (try? JSONDecoder().decode(Value.self, from: existing)) == nil {
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
                // Без копии старый файл не затираем: в нём могут быть данные, которые ещё можно спасти.
                do { try manager.copyItem(at: url, to: backup) } catch { return false }
            }
        }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic, protection])
            return true
        } catch {
            return false
        }
    }

    func delete() {
        let manager = FileManager.default
        // Файл, который сейчас нельзя прочитать (телефон не разблокирован), не удаляем: в нём могут быть данные.
        if manager.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil { return }
        try? manager.removeItem(at: url)
    }
}

enum AppFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Копия файла, который не удалось прочитать: лежит рядом с рабочим файлом.
    struct BackupFile: Identifiable {
        let url: URL
        /// Имя рабочего файла без расширения, например «journal».
        let base: String
        let date: Date
        var id: URL { url }

        /// Как это назвать человеку.
        var title: String {
            switch base {
            case "alarms": return "Будильники"
            case "journal": return "Дневник подъёмов"
            case "challenges": return "Челленджи"
            case "settings": return "Настройки"
            case "meds": return "Лекарства"
            default: return base
            }
        }
    }

    /// Самая свежая копия для каждого файла.
    static func corruptBackups() -> [BackupFile] {
        let names = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        var newest: [String: BackupFile] = [:]
        for url in names {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json"), let range = name.range(of: ".corrupt-") else { continue }
            let base = String(name[..<range.lowerBound])
            let stampText = name[range.upperBound...].dropLast(".json".count)
            guard let stamp = TimeInterval(stampText) else { continue }
            let file = BackupFile(url: url, base: base, date: Date(timeIntervalSince1970: stamp))
            if let current = newest[base], current.date >= file.date { continue }
            newest[base] = file
        }
        return newest.values.sorted { $0.date > $1.date }
    }

    /// Возвращает данные из копии. Текущий файл перед этим сохраняется рядом (имя «.before-restore-…»).
    @discardableResult
    static func restore(_ backup: BackupFile) -> Bool {
        let manager = FileManager.default
        let target = documents.appendingPathComponent(backup.base + ".json")
        guard let data = try? Data(contentsOf: backup.url) else { return false }
        if manager.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let keep = documents.appendingPathComponent("\(backup.base).before-restore-\(stamp).json")
            guard (try? manager.copyItem(at: target, to: keep)) != nil else { return false }
        }
        return (try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    /// Удаляет все данные приложения на телефоне: файлы, фоны, настройки.
    static func wipeAll() {
        let manager = FileManager.default
        if let items = try? manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            for item in items {
                try? manager.removeItem(at: item)
            }
        }
        // Записи своего голоса лежат вне Documents (в Library/Sounds).
        VoiceLibrary.wipeFiles()
        // Временные файлы: собранный ролик, черновик записи голоса.
        let temporary = manager.temporaryDirectory
        if let items = try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            for item in items { try? manager.removeItem(at: item) }
        }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }
}
