import CryptoKit
import Foundation

/// Условия ставки, на которые человек соглашается заранее. При изменении текста повышается версия,
/// и согласие спрашивается заново.
enum StakeTerms {
    static let version = 1

    static func clauses(amount: Int, isTraining: Bool) -> [String] {
        var list = [
            "Ставка \(amount) ₽ на каждое утро этого будильника.",
            "Чтобы ставка не списалась, нужно: нажать «Выключить», за 10 минут выполнить задание, а когда через 10 минут будильник прозвенит снова, выполнить второе задание тоже за 10 минут.",
            "Если хотя бы одно из двух заданий не выполнено вовремя, ставка списывается. Это так, даже если вы уже встали: проснуться, но не пройти вторую проверку, считается провалом.",
            "Если в течение 10 минут после звонка вы не нажали «Выключить» и не открыли приложение, ставка списывается.",
            "Если вы сами выключили разрешение на будильники, выключили телефон или звук, ставка списывается.",
            "Ставка не списывается только в одном случае: будильник не был поставлен в систему из-за сбоя приложения или телефона.",
            "Прощений, пауз и исключений нет: каждое проспанное утро — списание.",
            "За 2 часа до звонка будильник со ставкой нельзя изменить, выключить или удалить.",
            "Ставку и списания видите только вы. Друзьям они не показываются.",
        ]
        if isTraining {
            list.append("Сейчас ставки тренировочные: все операции записываются, но деньги не списываются.")
        }
        return list
    }

    /// Нужно ли спросить согласие: его нет, условия изменились или сумма больше той, на которую соглашались.
    static func needsConsent(_ consent: StakeConsent?, amount: Int) -> Bool {
        guard let consent else { return true }
        return consent.version < version || amount > consent.maxAmount
    }
}

/// Согласие с условиями ставки. Хранится на телефоне и уходит на сервер как доказательство для споров.
struct StakeConsent: Codable, Equatable {
    var version: Int
    var acceptedAt: Date
    /// Самая большая сумма, на которую человек соглашался.
    var maxAmount: Int
}

enum WakeEventKind: String, Codable {
    case started      // нажал «Выключить», открылось задание
    case taskDone     // первое задание выполнено
    case recheckDone  // вторая проверка пройдена: утро успешно
    case failed       // время вышло, пока приложение было открыто
}

/// Событие утра для сервера. Подписано секретом устройства: подделать «встал» нельзя.
/// Если утром не было сети, событие уйдёт позже, и сервер по нему вернёт ошибочно списанное.
struct WakeEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Номер утра: будильник и время звонка.
    var morningID: String
    var alarmID: UUID
    var ring: Date
    var kind: WakeEventKind
    /// Время события по защищённым часам.
    var at: Date
    var signature: String

    static func morningID(alarmID: UUID, ring: Date) -> String {
        "\(alarmID.uuidString)|\(Int(ring.timeIntervalSince1970))"
    }

    /// Что подписывается: номер утра, вид события и время в секундах (с той же точностью дата уходит на сервер).
    static func signedMessage(morningID: String, kind: WakeEventKind, at: Date) -> String {
        "\(morningID)|\(kind.rawValue)|\(Int(at.timeIntervalSince1970))"
    }

    /// HMAC-SHA256 в base64.
    static func sign(_ message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }
}
