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
        await run {
            try await backend.removeFriend(friend.id)
            friends.removeAll { $0.id == friend.id }
        }
    }

    func setVisibility(_ visibility: Visibility, for friend: Friend) async {
        await run {
            try await backend.setVisibility(visibility, for: friend.id)
            if let index = friends.firstIndex(where: { $0.id == friend.id }) {
                friends[index].myVisibility = visibility
            }
        }
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

    func send(_ text: String, to conversation: ConversationID) async {
        guard AppSettings.shared.data.isAdult else {
            errorText = "Чаты доступны с \(AppConfig.adultAge) лет."
            return
        }
        guard ContentFilter.isSendable(text) else { return }
        let cleaned = ContentFilter.clean(text)
        await run {
            let message = try await backend.send(cleaned, to: conversation)
            messages[conversation, default: []].append(message)
        }
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
        let settings = AppSettings.shared.data
        let entries = JournalStore.shared.realEntries
        let snapshot = ProgressEngine.compute(entries: entries, challenges: ChallengeStore.shared.challenges)
        let status = PublicStatusBuilder.build(entries: entries, snapshot: snapshot, privacy: settings.privacy, now: Date())
        Task { try? await backend.publishStatus(status) }
    }
}
