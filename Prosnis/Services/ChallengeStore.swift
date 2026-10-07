import Foundation
import SwiftUI

/// Личные челленджи и их история («летопись»).
@MainActor
final class ChallengeStore: ObservableObject {
    static let shared = ChallengeStore()

    @Published private(set) var challenges: [Challenge] = []

    private let file = FileStore<[Challenge]>("challenges")

    private var loadFailed = false

    private init() {
        reload()
    }

    func reload() {
        let result = file.loadWithState()
        challenges = result.value ?? []
        loadFailed = result.state == .unreadable
    }

    func reloadIfNeeded() {
        if loadFailed { reload() }
    }

    private func save() { file.save(challenges) }

    private func sync(_ challenge: Challenge) {
        if challenge.isPrivate && !AppSettings.shared.data.privacy.syncPrayerData { return }
        SyncEngine.shared.enqueue(.challenge, id: challenge.id, value: challenge, sensitive: challenge.isPrivate)
    }

    var active: [Challenge] { challenges.filter { $0.status == .active } }
    var finished: [Challenge] {
        challenges.filter { $0.status != .active }.sorted { ($0.endedAt ?? $0.startDate) > ($1.endedAt ?? $1.startDate) }
    }

    func add(_ challenge: Challenge) {
        challenges.append(challenge)
        save()
        sync(challenge)
        evaluateAll()
    }

    func abandon(_ id: UUID) {
        guard let index = challenges.firstIndex(where: { $0.id == id }), challenges[index].status == .active else { return }
        challenges[index].status = .abandoned
        challenges[index].endedAt = Date()
        challenges[index].updatedAt = Date()
        save()
        sync(challenges[index])
    }

    func progress(for challenge: Challenge, now: Date = Date()) -> ChallengeProgress {
        ChallengeEvaluator.evaluate(challenge, entries: JournalStore.shared.realEntries, now: now)
    }

    /// Пересчитывает статусы идущих челленджей по журналу.
    func evaluateAll(now: Date = Date()) {
        var changed = false
        for index in challenges.indices where challenges[index].status == .active {
            let result = progress(for: challenges[index], now: now)
            if result.status != .active {
                challenges[index].status = result.status
                challenges[index].endedAt = result.endedAt
                challenges[index].updatedAt = now
                sync(challenges[index])
                changed = true
            }
        }
        if changed { save() }
    }
}

/// Что происходит после изменения журнала.
@MainActor
enum AppEvents {
    /// `isNew` — запись только что появилась (а не обновилась чек-листом или спором).
    static func journalChanged(_ entry: JournalEntry, isNew: Bool = false) {
        ChallengeStore.shared.evaluateAll()
        if isNew {
            SocialStore.shared.notifyWitnesses(about: entry)
        }
        let mayLeave = entry.isPrayer != true || AppSettings.shared.data.privacy.syncPrayerData
        if entry.isDemo != true && mayLeave {
            // Уходит на свой сервер (нужен для платежей и проверки рекордов), друзьям не показывается.
            SyncEngine.shared.enqueue(.journalEntry, id: entry.id, value: entry, sensitive: entry.isPrayer == true)
        }
        // Утро с намазом без согласия не должно даже менять статус: время отправки выдало бы ранний подъём.
        if entry.isPrayer != true || AppSettings.shared.data.privacy.sharePrayer {
            SocialStore.shared.publishStatus()
        }
    }
}
