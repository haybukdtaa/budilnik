import Foundation

enum BackendError: LocalizedError, Equatable {
    case serverUnavailable
    case notFound
    case invalidCode
    case forbidden
    case rateLimited
    case roomFull
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable: return "Сервер ещё не подключён. Включите демо-режим в Профиле, чтобы посмотреть, как это будет работать."
        case .notFound: return "Не найдено."
        case .invalidCode: return "Код не подошёл. Проверьте его и попробуйте снова."
        case .forbidden: return "Нет доступа."
        case .rateLimited: return "Слишком часто. Попробуйте позже."
        case .roomFull: return "В комнате уже максимальное число участников."
        case .server(let code): return "Ошибка сервера (\(code)). Попробуйте позже."
        }
    }
}

/// Всё общение приложения с сервером в части друзей, комнат, чатов и таблиц.
/// Реализации: без сервера (Offline), демо на телефоне (Demo) и настоящий сервер (HTTP).
@MainActor
protocol SocialBackend: AnyObject {
    var isOnline: Bool { get }
    var isDemo: Bool { get }

    func friends() async throws -> [Friend]
    func createInvite() async throws -> Invite
    func acceptInvite(code: String) async throws -> Friend
    func removeFriend(_ id: UUID) async throws
    func setVisibility(_ visibility: Visibility, for friend: UUID) async throws
    func nudge(friend: UUID) async throws

    func rooms() async throws -> [Room]
    func createRoom(_ draft: RoomDraft) async throws -> Room
    func joinRoom(code: String) async throws -> Room
    func leaveRoom(_ id: UUID) async throws

    func messages(in conversation: ConversationID) async throws -> [ChatMessage]
    func send(_ text: String, to conversation: ConversationID) async throws -> ChatMessage
    func report(message: UUID, reason: String) async throws
    func block(user: UUID) async throws

    func leaderboard(_ kind: LeaderboardKind) async throws -> Leaderboard
    func globalStats() async throws -> GlobalStats
    func publishStatus(_ status: PublicStatus) async throws
    func inviteRewards() async throws -> [InviteReward]
    func pairChallenges() async throws -> [PairChallenge]
    func createPairChallenge(with friend: UUID, title: String, days: Int) async throws -> PairChallenge

    func deleteAccount() async throws

    /// Сообщить свидетелям, что я проспал (сервер рассылает им уведомление).
    func notifyWitnesses(_ notice: MissedMorningNotice) async throws
    /// Друзья, у которых я свидетель и которые проспали за последние дни.
    func witnessNotices() async throws -> [WitnessNotice]

    func gardens() async throws -> [SharedGarden]
    func createGarden(_ draft: GardenDraft) async throws -> SharedGarden
    func joinGarden(code: String) async throws -> SharedGarden
    func leaveGarden(_ id: UUID) async throws
    /// Полить все мои сады этим утром (день «гггг-мм-дд»). Один полив в день, повтор ничего не меняет.
    func waterGardens(day: String) async throws -> [SharedGarden]
}

/// Синхронизация локальных данных (будильники, журнал, челленджи) с сервером.
@MainActor
protocol SyncBackend: AnyObject {
    /// Отправляет изменения, возвращает id принятых.
    func push(_ items: [OutboxItem]) async throws -> [UUID]
    func serverTime() async throws -> Date
}

/// Пока сервера нет: всё отвечает «сервер не подключён».
@MainActor
final class OfflineBackend: SocialBackend, SyncBackend {
    var isOnline: Bool { false }
    var isDemo: Bool { false }

    private func unavailable<T>() throws -> T { throw BackendError.serverUnavailable }

    func friends() async throws -> [Friend] { try unavailable() }
    func createInvite() async throws -> Invite { try unavailable() }
    func acceptInvite(code: String) async throws -> Friend { try unavailable() }
    func removeFriend(_ id: UUID) async throws { throw BackendError.serverUnavailable }
    func setVisibility(_ visibility: Visibility, for friend: UUID) async throws { throw BackendError.serverUnavailable }
    func nudge(friend: UUID) async throws { throw BackendError.serverUnavailable }
    func rooms() async throws -> [Room] { try unavailable() }
    func createRoom(_ draft: RoomDraft) async throws -> Room { try unavailable() }
    func joinRoom(code: String) async throws -> Room { try unavailable() }
    func leaveRoom(_ id: UUID) async throws { throw BackendError.serverUnavailable }
    func messages(in conversation: ConversationID) async throws -> [ChatMessage] { try unavailable() }
    func send(_ text: String, to conversation: ConversationID) async throws -> ChatMessage { try unavailable() }
    func report(message: UUID, reason: String) async throws { throw BackendError.serverUnavailable }
    func block(user: UUID) async throws { throw BackendError.serverUnavailable }
    func leaderboard(_ kind: LeaderboardKind) async throws -> Leaderboard { try unavailable() }
    func globalStats() async throws -> GlobalStats { try unavailable() }
    func publishStatus(_ status: PublicStatus) async throws { throw BackendError.serverUnavailable }
    func inviteRewards() async throws -> [InviteReward] { try unavailable() }
    func pairChallenges() async throws -> [PairChallenge] { try unavailable() }
    func createPairChallenge(with friend: UUID, title: String, days: Int) async throws -> PairChallenge { try unavailable() }
    func deleteAccount() async throws {}
    func notifyWitnesses(_ notice: MissedMorningNotice) async throws { throw BackendError.serverUnavailable }
    func witnessNotices() async throws -> [WitnessNotice] { try unavailable() }
    func gardens() async throws -> [SharedGarden] { try unavailable() }
    func createGarden(_ draft: GardenDraft) async throws -> SharedGarden { try unavailable() }
    func joinGarden(code: String) async throws -> SharedGarden { try unavailable() }
    func leaveGarden(_ id: UUID) async throws { throw BackendError.serverUnavailable }
    func waterGardens(day: String) async throws -> [SharedGarden] { try unavailable() }

    func push(_ items: [OutboxItem]) async throws -> [UUID] { try unavailable() }
    func serverTime() async throws -> Date { try unavailable() }
}
