import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Код восстановления: 16 простых слов. Из них выводятся номер аккаунта и секрет устройства,
/// поэтому на новом телефоне эти слова возвращают тот же аккаунт. Без регистрации, телефона и почты.
enum RecoveryPhrase {
    static let wordCount = 16
    /// Повторов медленного вывода ключа: каждая попытка перебора стоит в сто тысяч раз дороже.
    static let kdfRounds: UInt32 = 100_000

    /// 256 слов: каждое слово — 8 бит, 16 слов — 128 бит. Подобрать такой код перебором невозможно
    /// ни через сервер, ни без него (даже зная номер аккаунта).
    static let words: [String] = [
        "дом", "лес", "сад", "мост", "кот", "сон", "мир", "луг", "дуб", "рак", "лук", "сыр", "чай", "суп", "хлеб", "соль",
        "река", "гора", "поле", "море", "небо", "звезда", "луна", "солнце", "ветер", "дождь", "снег", "туман", "облако", "радуга", "заря", "закат",
        "утро", "вечер", "ночь", "неделя", "месяц", "весна", "лето", "осень", "зима", "север", "юг", "запад", "восток", "остров", "берег", "залив",
        "камень", "песок", "глина", "ручей", "озеро", "пруд", "волна", "парус", "лодка", "якорь", "маяк", "порт", "город", "улица", "площадь", "парк",
        "школа", "книга", "тетрадь", "ручка", "карта", "глобус", "компас", "часы", "лампа", "свеча", "окно", "дверь", "крыша", "стена", "пол", "лестница",
        "стол", "стул", "шкаф", "полка", "диван", "кровать", "подушка", "одеяло", "чашка", "ложка", "вилка", "тарелка", "кастрюля", "чайник", "ведро", "корзина",
        "яблоко", "груша", "слива", "вишня", "малина", "клубника", "арбуз", "дыня", "лимон", "апельсин", "банан", "виноград", "морковь", "капуста", "тыква", "огурец",
        "орех", "гриб", "ягода", "цветок", "роза", "тюльпан", "ромашка", "лилия", "липа", "сосна", "ель", "кедр", "ива", "тополь", "пальма", "бамбук",
        "лиса", "волк", "медведь", "заяц", "белка", "олень", "лось", "барсук", "енот", "тигр", "лев", "слон", "жираф", "зебра", "верблюд", "конь",
        "корова", "коза", "овца", "собака", "мышь", "крыса", "хомяк", "кролик", "утка", "гусь", "курица", "петух", "голубь", "ворона", "сова", "сокол",
        "рыба", "кит", "дельфин", "акула", "краб", "медуза", "креветка", "тюлень", "пингвин", "чайка", "аист", "журавль", "лебедь", "цапля", "попугай", "павлин",
        "ключ", "замок", "сундук", "монета", "кольцо", "браслет", "бусы", "зеркало", "гребень", "шарф", "шапка", "перчатка", "сапог", "ботинок", "пальто", "куртка",
        "рубашка", "платье", "юбка", "носок", "пуговица", "нитка", "игла", "ножницы", "молоток", "гвоздь", "пила", "топор", "лопата", "грабли", "кисть", "краска",
        "гитара", "скрипка", "барабан", "флейта", "труба", "рояль", "песня", "танец", "театр", "кино", "музей", "цирк", "праздник", "подарок", "шар", "флаг",
        "поезд", "вагон", "рельс", "трамвай", "автобус", "машина", "велосипед", "ракета", "корабль", "самокат", "колесо", "руль", "мотор", "бензин", "дорога", "тропа",
        "мяч", "кубок", "медаль", "спорт", "бег", "прыжок", "лыжи", "коньки", "сани", "горка", "каток", "стадион", "команда", "игра", "урок", "экзамен",
    ]

    /// Новый случайный код.
    static func generate() -> [String] {
        var bytes = [UInt8](repeating: 0, count: wordCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<wordCount).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { words[Int($0)] }
    }

    /// Разбирает введённый код: регистр, «ё», запятые и лишние пробелы не важны. nil — код неверный.
    static func parse(_ text: String) -> [String]? {
        let cleaned = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let parts = cleaned.split { $0.isWhitespace || $0 == "," || $0 == "." || $0 == ";" }.map(String.init)
        guard parts.count == wordCount, parts.allSatisfy({ words.contains($0) }) else { return nil }
        return parts
    }

    /// Номер аккаунта и секрет устройства, однозначно выведенные из кода через PBKDF2.
    /// Номер и секрет получаются из общего ключа разными путями: по номеру секрет не узнать.
    static func identity(for phrase: [String]) -> (userID: UUID, secret: String) {
        let seed = derive(phrase.joined(separator: " "))
        let idHash = Data(SHA256.hash(data: Data("id|".utf8) + seed))
        var b = Array(idHash.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40 // UUID версии 4
        b[8] = (b[8] & 0x3F) | 0x80
        let userID = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        let secret = Data(SHA256.hash(data: Data("secret|".utf8) + seed)).base64EncodedString()
        return (userID, secret)
    }

    private static func derive(_ password: String) -> Data {
        let passwordBytes = Array(password.utf8)
        let salt = Array("prosnis-recovery-v2".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { passwordPointer in
            passwordPointer.withMemoryRebound(to: Int8.self) { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), kdfRounds,
                    &derived, derived.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 не сработал")
        return Data(derived)
    }
}

/// Номер для друзей вида PRO-482-913-075. Выдаёт сервер: случайный и уникальный, не по порядку,
/// чтобы номера нельзя было перебирать подряд.
enum FriendNumber {
    static let digits = 9

    /// Приводит ввод к виду PRO-XXX-XXX-XXX. nil — в номере не 9 цифр.
    static func normalize(_ text: String) -> String? {
        let numbers = text.filter { ("0"..."9").contains($0) }
        guard numbers.count == digits else { return nil }
        return format(numbers)
    }

    static func format(_ numbers: String) -> String {
        let chars = Array(numbers)
        return "PRO-" + String(chars[0..<3]) + "-" + String(chars[3..<6]) + "-" + String(chars[6..<9])
    }

    /// Номер для демо-режима (без сервера): выводится из номера аккаунта, только для показа.
    static func demo(for id: UUID) -> String {
        let hash = SHA256.hash(data: Data(id.uuidString.utf8))
        let value = hash.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000_000
        return format(String(format: "%09llu", value))
    }
}
