import Foundation
import SwiftUI

/// Данные сообщества на экране: друзья, комнаты, чаты, таблицы. Ходит в текущий сервер.
@MainActor
final class SocialStore: ObservableObject {
    static let shared = SocialStore()

    @Published private(set) var friends: [Friend] = []
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var leaderboards: [LeaderboardKind: Leaderboard] = [:]
    @Published private(set) var stats: GlobalStats?
    @Published private(set) var rewards: [InviteReward] = []
    @Published private(set) var pairs: [PairChallenge] = []
    @Published private(set) var messages: [ConversationID: [ChatMessage]] = [:]
    @Published private(set) var invite: Invite?
    @Published private(set) var witnessNotices: [WitnessNotice] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?

    private init() {}

    var backend: SocialBackend { BackendRegistry.current }
    var isAvailable: Bool { backend.isOnline }
    var isDemo: Bool { backend.isDemo }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func refresh() async {
        guard backend.isOnline else {
            resetAfterWipe()
            return
        }
        isLoading = true
        defer { isLoading = false }
        await run {
            friends = try await backend.friends()
            rooms = try await backend.rooms()
            stats = try await backend.globalStats()
            pairs = try await backend.pairChallenges()
            rewards = try await backend.inviteRewards()
        }
        // Отдельно: сервер без этого раздела не должен ломать всё остальное.
        let blocked = Set(AppSettings.shared.data.blockedUsers)
        witnessNotices = ((try? await backend.witnessNotices()) ?? []).filter { !blocked.contains($0.friend.id) }
        let unlocked = rewards.filter(\.unlocked).map(\.id)
        if Set(unlocked) != Set(AppSettings.shared.data.unlockedRewards) {
            AppSettings.shared.data.unlockedRewards = unlocked
        }
    }

    func resetAfterWipe() {
        friends = []
        rooms = []
        leaderboards = [:]
        stats = nil
        rewards = []
        pairs = []
        messages = [:]
        invite = nil
        witnessNotices = []
    }

    // MARK: - Друзья

    func createInvite() async {
        await run { invite = try await backend.createInvite() }
    }

    func acceptInvite(code: String) async -> Bool {
        var ok = false
        await run {
            let friend = try await backend.acceptInvite(code: code)
            friends.append(friend)
            ok = true
        }
        return ok
    }

    func removeFriend(_ friend: Friend) async {
        // Свидетелем человек перестаёт сразу, даже если сервер сейчас недоступен.
        AppSettings.shared.setWitness(friend.id, false)
        await run {
            try await backend.removeFriend(friend.id)
            friends.removeAll { $0.id == friend.id }
        }
    }

    @discardableResult
    func setVisibility(_ visibility: Visibility, for friend: Friend) async -> Bool {
        var ok = false
        await run {
            try await backend.setVisibility(visibility, for: friend.id)
            if let index = friends.firstIndex(where: { $0.id == friend.id }) {
                friends[index].myVisibility = visibility
            }
            ok = true
        }
        return ok
    }

    /// Сколько раз ещё можно «разбудить» друга сегодня.
    func nudgesLeft(for friend: Friend, now: Date = Date()) -> Int {
        let sent = AppSettings.shared.data.nudges[friend.id.uuidString] ?? []
        let today = sent.filter { Calendar.current.isDate($0, inSameDayAs: now) }
        return max(0, AppConfig.nudgesPerFriendPerDay - today.count)
    }

    func nudge(_ friend: Friend) async -> Bool {
        guard nudgesLeft(for: friend) > 0 else {
            errorText = "Сегодня вы уже будили этого друга \(AppConfig.nudgesPerFriendPerDay) раза."
            return false
        }
        var ok = false
        await run {
            try await backend.nudge(friend: friend.id)
            let now = Date()
            var list = (AppSettings.shared.data.nudges[friend.id.uuidString] ?? []).filter { now.timeIntervalSince($0) < 86400 }
            list.append(now)
            AppSettings.shared.data.nudges[friend.id.uuidString] = list
            ok = true
        }
        return ok
    }

    // MARK: - Комнаты

    func createRoom(_ draft: RoomDraft) async -> Room? {
        var created: Room?
        await run {
            let room = try await backend.createRoom(draft)
            rooms.append(room)
            created = room
        }
        return created
    }

    func joinRoom(code: String) async -> Room? {
        var joined: Room?
        await run {
            let room = try await backend.joinRoom(code: code)
            if !rooms.contains(where: { $0.id == room.id }) { rooms.append(room) }
            joined = room
        }
        return joined
    }

    func leaveRoom(_ room: Room) async {
        await run {
            try await backend.leaveRoom(room.id)
            rooms.removeAll { $0.id == room.id }
        }
    }

    // MARK: - Чаты

    func loadMessages(_ conversation: ConversationID) async {
        await run { messages[conversation] = try await backend.messages(in: conversation) }
    }

    func visibleMessages(_ conversation: ConversationID) -> [ChatMessage] {
        (messages[conversation] ?? []).filter { !AppSettings.shared.isBlocked($0.author.id) }
    }

    @discardableResult
    func send(_ text: String, to conversation: ConversationID) async -> Bool {
        guard AppSettings.shared.data.isAdult else {
            errorText = "Чаты доступны с \(AppConfig.adultAge) лет."
            return false
        }
        guard ContentFilter.isSendable(text) else { return false }
        let cleaned = ContentFilter.clean(text)
        var ok = false
        await run {
            let message = try await backend.send(cleaned, to: conversation)
            messages[conversation, default: []].append(message)
            ok = true
        }
        return ok
    }

    func report(_ message: ChatMessage) async {
        await run {
            try await backend.report(message: message.id, reason: "Жалоба пользователя")
            errorText = "Жалоба отправлена. Спасибо."
        }
    }

    func block(_ user: UserProfile) async {
        if !AppSettings.shared.data.blockedUsers.contains(user.id) {
            AppSettings.shared.data.blockedUsers.append(user.id)
        }
        AppSettings.shared.setWitness(user.id, false)
        witnessNotices.removeAll { $0.friend.id == user.id }
        await run { try await backend.block(user: user.id) }
    }

    func unblockAll() {
        AppSettings.shared.data.blockedUsers = []
    }

    // MARK: - Таблицы и парные челленджи

    func loadLeaderboard(_ kind: LeaderboardKind) async {
        await run { leaderboards[kind] = try await backend.leaderboard(kind) }
    }

    func createPair(with friend: Friend, title: String, days: Int) async {
        await run {
            let pair = try await backend.createPairChallenge(with: friend.id, title: title, days: days)
            pairs.append(pair)
        }
    }

    // MARK: - Статус

    /// Отправляет друзьям статус дня в пределах настроек приватности.
    func publishStatus() {
        let backend = self.backend
        guard backend.isOnline else { return }
        let privacy = AppSettings.shared.data.privacy
        let entries = PublicStatusBuilder.shareableEntries(JournalStore.shared.realEntries, privacy: privacy)
        let challenges = PublicStatusBuilder.shareableChallenges(ChallengeStore.shared.challenges, privacy: privacy)
        let snapshot = ProgressEngine.compute(entries: entries, challenges: challenges)
        // Вид — того дерева, которое человек видит у себя (вид не выдаёт ничего личного).
        let ownTree = ProgressEngine.compute(entries: JournalStore.shared.realEntries, challenges: []).tree
        let species = AppSettings.shared.species(forTree: ownTree.index)
        let status = PublicStatusBuilder.build(
            entries: JournalStore.shared.realEntries, snapshot: snapshot, privacy: privacy, now: Date(), species: species
        )
        Task { try? await backend.publishStatus(status) }
    }

    /// Сообщает друзьям-свидетелям о проспанном утре. Без сервера ничего не отправляется.
    func notifyWitnesses(about entry: JournalEntry) {
        let settings = AppSettings.shared.data
        let blocked = Set(settings.blockedUsers)
        var recipients = settings.witnesses.filter { !blocked.contains($0) }
        if !friends.isEmpty {
            let current = Set(friends.map(\.id))
            recipients = recipients.filter { current.contains($0) }
        }
        guard WitnessPolicy.shouldNotify(
            entry: entry, privacy: settings.privacy, witnesses: recipients,
            now: Date(), lastNotifiedDay: settings.lastWitnessNoticeDay
        ) else { return }
        let notice = MissedMorningNotice(day: WitnessPolicy.dayKey(entry.date), witnesses: recipients)
        AppSettings.shared.data.lastWitnessNoticeDay = notice.day
        AppSettings.shared.data.pendingWitnessNotice = notice
        sendPendingWitnessNotice()
    }

    /// Отправляет отложенное сообщение свидетелям (если не ушло из-за сети). Старше суток — отбрасывается.
    func sendPendingWitnessNotice() {
        guard let notice = AppSettings.shared.data.pendingWitnessNotice else { return }
        if notice.day < WitnessPolicy.dayKey(Date().addingTimeInterval(-WitnessPolicy.freshness)) {
            AppSettings.shared.data.pendingWitnessNotice = nil
            return
        }
        let backend = self.backend
        guard backend.isOnline else { return }
        Task {
            do {
                try await backend.notifyWitnesses(notice)
                if AppSettings.shared.data.pendingWitnessNotice == notice {
                    AppSettings.shared.data.pendingWitnessNotice = nil
                }
            } catch {
                // Останется в очереди: повторим при следующем открытии.
            }
        }
    }
}
