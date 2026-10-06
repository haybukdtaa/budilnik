import Foundation
import SwiftUI

struct PaymentHold: Codable, Equatable {
    var reference: UUID
    var amount: Int
    var createdAt: Date
}

struct PaymentMethodStatus: Codable, Equatable {
    var isOK: Bool
    var message: String
    var checkedAt: Date
}

enum LedgerKind: String, Codable {
    case hold, capture, release, refund

    var title: String {
        switch self {
        case .hold: return "Блокировка ставки"
        case .capture: return "Списание"
        case .release: return "Снятие блокировки"
        case .refund: return "Возврат"
        }
    }
}

/// Запись о денежной операции. Видна только владельцу, никуда не публикуется.
struct LedgerRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var kind: LedgerKind
    var amount: Int
    var reference: UUID
    var isTraining: Bool
}

/// Способ оплаты ставок. Сейчас тренировочный; карта или кошелёк подключаются отдельной реализацией.
@MainActor
protocol PaymentProvider: AnyObject {
    var title: String { get }
    var isTraining: Bool { get }
    func checkMethod() async -> PaymentMethodStatus
    func hold(amount: Int, reference: UUID) async throws -> PaymentHold
    func capture(_ hold: PaymentHold) async throws
    func release(_ hold: PaymentHold) async throws
    func refund(reference: UUID, amount: Int) async throws
}

/// Деньги не двигаются, операции только записываются.
@MainActor
final class TrainingPaymentProvider: PaymentProvider {
    var title: String { "Тренировка: деньги не списываются" }
    var isTraining: Bool { true }

    func checkMethod() async -> PaymentMethodStatus {
        PaymentMethodStatus(isOK: true, message: "Тренировочный режим, карта не нужна", checkedAt: Date())
    }

    func hold(amount: Int, reference: UUID) async throws -> PaymentHold {
        PaymentHold(reference: reference, amount: amount, createdAt: Date())
    }

    func capture(_ hold: PaymentHold) async throws {}
    func release(_ hold: PaymentHold) async throws {}
    func refund(reference: UUID, amount: Int) async throws {}
}

/// Ставки и деньги. Данные хранятся отдельно от всего социального и никогда не публикуются.
@MainActor
final class PaymentsStore: ObservableObject {
    static let shared = PaymentsStore()

    private struct State: Codable {
        var ledger: [LedgerRecord] = []
        var holds: [UUID: PaymentHold] = [:]
        var lastStatus: PaymentMethodStatus?
    }

    @Published private(set) var ledger: [LedgerRecord] = []
    @Published private(set) var lastStatus: PaymentMethodStatus?

    let provider: PaymentProvider = TrainingPaymentProvider()
    private var holds: [UUID: PaymentHold] = [:]
    private let file = FileStore<State>("payments", protection: .completeFileProtectionUntilFirstUserAuthentication)

    private init() { load() }

    private func load() {
        let state = file.load() ?? State()
        ledger = state.ledger
        holds = state.holds
        lastStatus = state.lastStatus
    }

    func reload() { load() }

    private func save() {
        file.save(State(ledger: ledger, holds: holds, lastStatus: lastStatus))
    }

    private func record(_ kind: LedgerKind, amount: Int, reference: UUID) {
        ledger.insert(
            LedgerRecord(date: Date(), kind: kind, amount: amount, reference: reference, isTraining: provider.isTraining),
            at: 0
        )
        save()
    }

    var isTraining: Bool { provider.isTraining }

    /// Проверка способа оплаты не чаще раза в неделю, чтобы отказ не случился в момент штрафа.
    func checkIfNeeded(now: Date = Date()) async {
        if let last = lastStatus, now.timeIntervalSince(last.checkedAt) < 7 * 86400 { return }
        lastStatus = await provider.checkMethod()
        save()
    }

    /// Итоги, пришедшие раньше, чем завершилась блокировка (ключ — ссылка, значение — успех).
    private var pendingOutcomes: [UUID: Bool] = [:]

    /// Блокирует ставку в начале утра по заранее выданной ссылке.
    @discardableResult
    func hold(amount: Int, reference: UUID) async -> Bool {
        guard amount > 0 else { return false }
        guard let hold = try? await provider.hold(amount: amount, reference: reference) else { return false }
        holds[reference] = hold
        record(.hold, amount: amount, reference: reference)
        if let outcome = pendingOutcomes.removeValue(forKey: reference) {
            await settle(reference: reference, success: outcome)
        }
        return true
    }

    /// Завершает утро: при успехе снимает блокировку, при провале списывает.
    func settle(reference: UUID?, success: Bool) async {
        guard let reference else { return }
        guard let hold = holds[reference] else {
            // Блокировка ещё не завершилась: применим итог, когда она придёт.
            pendingOutcomes[reference] = success
            return
        }
        do {
            if success {
                try await provider.release(hold)
                record(.release, amount: hold.amount, reference: reference)
            } else {
                try await provider.capture(hold)
                record(.capture, amount: hold.amount, reference: reference)
            }
            holds[reference] = nil
            save()
        } catch {
            // Блокировка остаётся; повторная попытка будет при следующем запуске.
            pendingOutcomes[reference] = success
        }
    }

    /// Повторяет незавершённые операции (например, после сбоя связи).
    func retryPending() async {
        for (reference, success) in pendingOutcomes where holds[reference] != nil {
            pendingOutcomes[reference] = nil
            await settle(reference: reference, success: success)
        }
    }

    func refund(reference: UUID, amount: Int) {
        Task {
            try? await provider.refund(reference: reference, amount: amount)
            record(.refund, amount: amount, reference: reference)
        }
    }
}
