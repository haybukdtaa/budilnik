import CryptoKit
import Foundation

/// Версия юридических текстов. При изменении любого текста число повышается, и согласия спрашиваются заново.
enum LegalVersion {
    static let current = 1
    /// Дата действия текущей редакции (показывается в документах).
    static let dateText = "21 октября 2026 года"
}

/// Виды согласий. Каждое даётся отдельно, отдельной галочкой, без предустановленной отметки.
enum ConsentKind: String, Codable, CaseIterable, Identifiable {
    /// Пользовательское соглашение и ознакомление с политикой конфиденциальности.
    case terms
    /// Обработка персональных данных на сервере: аккаунт, друзья, сообщество, восстановление.
    case personalData
    /// Особые категории (сведения о религиозных убеждениях: намаз). Только по отдельному согласию.
    case specialData
    /// Данные, разрешённые для распространения неограниченному кругу (таблицы, клубы).
    case distribution
    /// Новости и предложения.
    case marketing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: return "Пользовательское соглашение и политика конфиденциальности"
        case .personalData: return "Обработка персональных данных на сервере"
        case .specialData: return "Данные о намазе (особая категория)"
        case .distribution: return "Показ данных всем участникам таблиц и клубов"
        case .marketing: return "Новости и предложения"
        }
    }

    /// Что именно человек разрешает, простыми словами.
    var summary: String {
        switch self {
        case .terms:
            return "Я прочитал(а) соглашение и политику и принимаю их условия."
        case .personalData:
            return "Хранить на сервере мой аккаунт, имя, аватар, будильники, дневник подъёмов и челленджи, чтобы работали друзья, сообщество и восстановление. Без этого приложение работает только на телефоне."
        case .specialData:
            return "Передавать на сервер данные о намазе (будильники по Фаджру и утра с намазом). Это сведения о религиозных убеждениях. Без согласия они остаются только на телефоне."
        case .distribution:
            return "Показывать моё имя, аватар и результаты всем участникам таблиц, комнат и клубов, где я состою. Остановить показ можно в любой момент."
        case .marketing:
            return "Присылать новости приложения. Необязательно: на работу приложения не влияет."
        }
    }

    /// Нужно ли это согласие для любой связи с сервером.
    var requiredForServer: Bool { self == .terms || self == .personalData }

    var document: LegalDocumentKind? {
        switch self {
        case .terms: return .terms
        case .personalData: return .personalData
        case .specialData: return .specialData
        case .distribution: return .distribution
        case .marketing: return nil
        }
    }
}

/// Согласие, данное или отозванное человеком. Хранится как доказательство: версия текста, время и отпечаток текста.
struct ConsentEntry: Codable, Equatable {
    var version: Int
    var date: Date
    var granted: Bool
    /// SHA-256 текста документа на момент решения (доказательство, что именно принято).
    var textHash: String?
}

/// То, что уходит на сервер при каждом изменении согласия.
struct ConsentRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: String
    var granted: Bool
    var version: Int
    var at: Date
    var textHash: String?
}

enum ConsentRules {
    static func isGranted(_ kind: ConsentKind, in entries: [String: ConsentEntry]) -> Bool {
        guard let entry = entries[kind.rawValue] else { return false }
        return entry.granted && entry.version == LegalVersion.current
    }

    /// Можно ли вообще обращаться к серверу: нужны оба обязательных согласия текущей редакции.
    static func serverAllowed(_ entries: [String: ConsentEntry]) -> Bool {
        ConsentKind.allCases.filter(\.requiredForServer).allSatisfy { isGranted($0, in: entries) }
    }

    /// Нужно ли показать окно согласий: соглашение ещё не рассматривали в текущей редакции.
    /// Отказ тоже ответ: повторно спрашиваем только при новой редакции или по просьбе самого человека.
    static func needsPrompt(_ entries: [String: ConsentEntry]) -> Bool {
        guard let entry = entries[ConsentKind.terms.rawValue] else { return true }
        return entry.version != LegalVersion.current
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Адрес электронной почты для восстановления.
enum EmailAddress {
    /// Приводит к виду для хранения или nil, если адрес непохож на настоящий.
    static func normalize(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 254, !value.contains(" ") else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return nil }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return nil }
        return value
    }

    /// Код из письма: ровно 6 цифр.
    static func normalizeCode(_ text: String) -> String? {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return digits.count == 6 ? digits : nil
    }
}
