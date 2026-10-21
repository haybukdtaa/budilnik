import Foundation

/// Любой JSON: нужен, чтобы сохранить ответ сервера как есть, не зная его полей заранее.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Не JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Данные человека с телефона. Секреты и код восстановления сюда не входят (они в связке ключей, не в файлах).
struct ExportBundle: Codable {
    var exportedAt: Date
    var appVersion: String
    var settings: SettingsData
    var alarms: [AlarmItem]
    var journal: [JournalEntry]
    var challenges: [Challenge]
    var medications: [Medication]
    var promises: [StepPromise]
}

private struct CompositeExport: Codable {
    var phone: ExportBundle
    var server: JSONValue?
}

/// «Скачать мои данные»: право на получение копии (статья 14 152-ФЗ) и просто честность перед человеком.
enum DataExport {
    @MainActor
    static func bundle() -> ExportBundle {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return ExportBundle(
            exportedAt: Date(),
            appVersion: version,
            settings: AppSettings.shared.data,
            alarms: AlarmStore.shared.alarms,
            journal: JournalStore.shared.entries,
            challenges: ChallengeStore.shared.challenges,
            medications: MedStore.shared.meds,
            promises: PromiseStore.shared.promises
        )
    }

    /// Собирает файл во временной папке. Возвращает адрес файла и пояснение (что вошло или почему часть не вошла).
    @MainActor
    static func prepare() async -> (url: URL?, note: String?) {
        var server: JSONValue?
        var note = "В файле данные с телефона."
        if let url = AppConfig.serverURL, AccountStore.shared.isSignedIn,
           ConsentRules.serverAllowed(AppSettings.shared.data.consents) {
            do {
                server = try await BackendRegistry.httpBackend(url).exportData()
                note = "В файле данные с телефона и данные вашего аккаунта с сервера."
            } catch {
                note = "Данные с телефона готовы, а данные с сервера получить не удалось (\(error.localizedDescription)). Повторите позже."
            }
        } else if AppConfig.serverURL != nil {
            note = "В файле данные с телефона. Серверных данных нет: нужны согласия и вход на сервер."
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(CompositeExport(phone: bundle(), server: server)) else {
            return (nil, "Не удалось подготовить файл.")
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("prosnis-data-\(stamp).json")
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return (nil, "Не удалось сохранить файл: \(error.localizedDescription)")
        }
        return (target, note)
    }
}
