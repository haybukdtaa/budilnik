import Foundation

enum FileLoadState: Equatable {
    case missing     // файла нет: первый запуск
    case loaded
    case unreadable  // файл есть, но закрыт (телефон ещё не разблокировали после включения)
    case corrupt     // файл есть, но не читается как данные (несовместимая версия)
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
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return (nil, .corrupt) }
        return (value, .loaded)
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
                try? manager.copyItem(at: url, to: backup)
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
        try? FileManager.default.removeItem(at: url)
    }
}

enum AppFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }
}
