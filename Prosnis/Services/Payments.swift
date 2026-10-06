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

/// Итог утра, который ещё не применён к блокировке.
struct PendingOutcome: Codable, Equatable {
    var success: Bool
    var amount: Int
}

/// Ставки и деньги. Данные хранятся отдельно от всего социального и никогда не публикуются.
/// Всё незавершённое (итоги, возвраты) сохраняется на диск и повторяется при следующем запуске.
@MainActor
final class PaymentsStore: ObservableObject {
    static let shared = PaymentsStore()

    private struct State: Codable {
        var ledger: [LedgerRecord] = []
        var holds: [UUID: PaymentHold] = [:]
        var lastStatus: PaymentMethodStatus?
        var pendingOutcomes: [UUID: PendingOutcome]?
        var pendingRefunds: [UUID: Int]?
    }

    @Published private(set) var ledger: [LedgerRecord] = []
    @Published private(set) var lastStatus: PaymentMethodStatus?

    let provider: PaymentProvider = TrainingPaymentProvider()
    private var holds: [UUID: PaymentHold] = [:]
    private var pendingOutcomes: [UUID: PendingOutcome] = [:]
    private var pendingRefunds: [UUID: Int] = [:]
    private var loadFailed = false
    private let file = FileStore<State>("payments")

    private init() { load() }

    private func load() {
        let result = file.loadWithState()
        let state = result.value ?? State()
        ledger = state.ledger
        holds = state.holds
        lastStatus = state.lastStatus
        pendingOutcomes = state.pendingOutcomes ?? [:]
        pendingRefunds = state.pendingRefunds ?? [:]
        loadFailed = result.state == .unreadable
    }

    func reload() { load() }

    func reloadIfNeeded() {
        if loadFailed { load() }
    }

    private func save() {
        file.save(State(
            ledger: ledger, holds: holds, lastStatus: lastStatus,
            pendingOutcomes: pendingOutcomes, pendingRefunds: pendingRefunds
        ))
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

    func hasHold(_ reference: UUID) -> Bool { holds[reference] != nil }

    /// Блокирует ставку по заранее выданной ссылке. Повторный вызов с той же ссылкой ничего не делает.
    @discardableResult
    func hold(amount: Int, reference: UUID) async -> Bool {
        guard amount > 0 else { return false }
        if holds[reference] != nil { return true }
        guard let hold = try? await provider.hold(amount: amount, reference: reference) else { return false }
        holds[reference] = hold
        record(.hold, amount: amount, reference: reference)
        if let outcome = pendingOutcomes[reference] {
            await settle(reference: reference, success: outcome.success, amount: outcome.amount)
        }
        return true
    }

    /// Завершает утро: при успехе снимает блокировку, при провале списывает.
    /// Если блокировки ещё нет, итог сохраняется и применится, когда она появится.
    func settle(reference: UUID?, success: Bool, amount: Int) async {
        guard let reference else { return }
        guard let hold = holds[reference] else {
            pendingOutcomes[reference] = PendingOutcome(success: success, amount: amount)
            save()
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
            pendingOutcomes[reference] = nil
            save()
        } catch {
            pendingOutcomes[reference] = PendingOutcome(success: success, amount: hold.amount)
            save()
        }
    }

    /// Повторяет всё незавершённое: блокировки без итога, итоги без блокировки, неудавшиеся возвраты.
    func retryPending() async {
        for (reference, outcome) in pendingOutcomes {
            if holds[reference] != nil {
                await settle(reference: reference, success: outcome.success, amount: outcome.amount)
            } else if outcome.success {
                // Утро успешное, а блокировки так и не было: делать ничего не нужно.
                pendingOutcomes[reference] = nil
                save()
            } else {
                // Провал, но блокировка не успела появиться: блокируем и сразу списываем.
                await hold(amount: outcome.amount, reference: reference)
            }
        }
        for (reference, amount) in pendingRefunds {
            await performRefund(reference: reference, amount: amount)
        }
    }

    /// Возврат по спору. Если списание ещё не прошло, вместо него снимается блокировка.
    func refund(reference: UUID, amount: Int) {
        Task {
            if holds[reference] != nil {
                pendingOutcomes[reference] = PendingOutcome(success: true, amount: amount)
                await settle(reference: reference, success: true, amount: amount)
                return
            }
            if let pending = pendingOutcomes[reference], !pending.success {
                pendingOutcomes[reference] = nil
                save()
                return
            }
            await performRefund(reference: reference, amount: amount)
        }
    }

    private func performRefund(reference: UUID, amount: Int) async {
        do {
            try await provider.refund(reference: reference, amount: amount)
            pendingRefunds[reference] = nil
            record(.refund, amount: amount, reference: reference)
        } catch {
            pendingRefunds[reference] = amount
            save()
        }
    }
}
