import Foundation
import SwiftUI

/// Личные челленджи и их история («летопись»).
@MainActor
final class ChallengeStore: ObservableObject {
    static let shared = ChallengeStore()

    @Published private(set) var challenges: [Challenge] = []

    private let file = FileStore<[Challenge]>("challenges")

    private init() {
        challenges = file.load() ?? []
    }

    func reload() { challenges = file.load() ?? [] }

    private func save() { file.save(challenges) }

    private func sync(_ challenge: Challenge) {
        if challenge.isPrivate && !AppSettings.shared.data.privacy.syncPrayerData { return }
        SyncEngine.shared.enqueue(.challenge, id: challenge.id, value: challenge)
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
    static func journalChanged(_ entry: JournalEntry) {
        ChallengeStore.shared.evaluateAll()
        let mayLeave = entry.isPrayer != true || AppSettings.shared.data.privacy.syncPrayerData
        if entry.isDemo != true && mayLeave {
            // Уходит на свой сервер (нужен для платежей и проверки рекордов), друзьям не показывается.
            SyncEngine.shared.enqueue(.journalEntry, id: entry.id, value: entry)
        }
        SocialStore.shared.publishStatus()
    }
}
