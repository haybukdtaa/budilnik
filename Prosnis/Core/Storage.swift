import Foundation

/// Одно значение Codable в файле Documents/<name>.json.
struct FileStore<Value: Codable> {
    let url: URL
    private let protection: Data.WritingOptions

    /// `protection`: по умолчанию файл доступен после первой разблокировки телефона,
    /// для чувствительных данных передавайте `.completeFileProtection`.
    init(_ name: String, protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication) {
        url = AppFiles.documents.appendingPathComponent(name + ".json")
        self.protection = protection
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, protection])
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
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }
}
